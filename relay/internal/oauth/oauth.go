// Package oauth is the relay's OAuth 2.1 authorization server for Claude (plan D4,
// contracts/mcp-surface.md): discovery metadata, client registration (CIMD and DCR),
// authorization code with PKCE S256, refresh rotation, revocation, and the bearer check on /mcp.
package oauth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/modelcontextprotocol/go-sdk/auth"
	"github.com/modelcontextprotocol/go-sdk/oauthex"
	"github.com/zitadel/oidc/v3/pkg/op"
	"golang.org/x/net/idna"

	"github.com/tonimelisma/latchkey/relay/internal/events"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Authenticator is the account side of /authorize: who is signed in, and the consent page.
type Authenticator interface {
	// CurrentUser returns the signed-in Owner, if any.
	CurrentUser(r *http.Request) (userID string, ok bool)
	// SignIn sends the browser to sign in and come back to r's URL.
	SignIn(w http.ResponseWriter, r *http.Request)
	// Consent renders the approval page; its form posts back to the same URL with a
	// "decision" field ("allow" or "deny") and a CSRF token.
	Consent(w http.ResponseWriter, r *http.Request, c ConsentRequest)
	// ValidCSRF checks the CSRF token of a posted form.
	ValidCSRF(r *http.Request) bool
}

// ConsentRequest is what the consent page shows.
type ConsentRequest struct {
	ClientName   string // the client's own claim, unverified; cleaned by cleanName
	ClientHost   string // what the relay checked (see verifiedHosts), in ASCII
	RedirectHost string
}

// Label is the client's name with the host the relay checked, e.g. "Claude (claude.ai)".
func (c ConsentRequest) Label() string { return clientLabel(c.ClientName, c.ClientHost) }

// maxNameRunes caps a client's name where the Owner sees it.
const maxNameRunes = 60

// cleanName makes a client's free-text name safe to show next to a host: no control or
// formatting characters (newlines, direction overrides, zero-width marks), no brackets of any
// kind in any script (Unicode's open and close punctuation: a name can't carry a "(host)" of its
// own, in ASCII or as fullwidth, small, or ornamental parentheses), runs of spaces collapsed, at
// most maxNameRunes.
func cleanName(name string) string {
	name = strings.Map(func(r rune) rune {
		switch {
		case unicode.IsSpace(r):
			return ' '
		case unicode.IsControl(r), unicode.Is(unicode.Cf, r), unicode.In(r, unicode.Ps, unicode.Pe), r == utf8.RuneError:
			return -1
		}
		return r
	}, name)
	name = strings.Join(strings.Fields(name), " ")
	if r := []rune(name); len(r) > maxNameRunes {
		name = strings.TrimSpace(string(r[:maxNameRunes-1])) + "\u2026"
	}
	return name
}

// displayHost shows a host in ASCII: an internationalized name appears in its xn-- form, so a
// look-alike such as a Cyrillic "с" in "сlaude.ai" can't pass for the real one.
func displayHost(host string) string {
	host = strings.ToLower(host)
	if a, err := idna.Punycode.ToASCII(host); err == nil {
		host = a
	}
	q := strconv.QuoteToASCII(host) // anything idna couldn't convert stays visibly escaped
	return q[1 : len(q)-1]
}

// clientLabel names a client wherever the Owner sees it (consent page, account page, the Mac's
// notice). Anyone can register a client called "Claude"; the host beside the name can't be
// chosen freely, so a look-alike shows a different one (security scan).
func clientLabel(name, host string) string {
	name = cleanName(name)
	switch {
	case name == "" && host == "":
		return "An unnamed app"
	case name == "":
		return host
	case host == "" || strings.EqualFold(name, host):
		return name
	}
	return name + " (" + host + ")"
}

// verifiedHosts is the part of a client's identity the relay checked, in ASCII: for a
// metadata-document client, the host it fetched the document from (its client ID); otherwise
// the hosts its codes are sent to: the given redirect URI's, or with none given (the account
// page, which names a client rather than one sign-in), every registered one's.
func verifiedHosts(cl *client, redirect *url.URL) []string {
	if isCIMD(cl.GetID()) {
		if u, err := url.Parse(cl.GetID()); err == nil {
			return []string{displayHost(u.Hostname())}
		}
	}
	if redirect != nil && redirect.Hostname() != "" {
		return []string{displayHost(redirect.Hostname())}
	}
	var out []string
	for _, raw := range cl.RedirectURIs() {
		if u, err := url.Parse(raw); err == nil && u.Hostname() != "" && !slices.Contains(out, displayHost(u.Hostname())) {
			out = append(out, displayHost(u.Hostname()))
		}
	}
	return out
}

// label names an approved client for the Owner.
func label(cl *client, redirect *url.URL) string {
	return clientLabel(cl.Name, strings.Join(verifiedHosts(cl, redirect), ", "))
}

// Config configures the server.
type Config struct {
	Issuer *url.URL // the relay's public origin
	Store  *store.Store
	Auth   Authenticator
	// HTTPClient fetches client metadata documents. Default: refuses private addresses.
	HTTPClient *http.Client
	Now        func() time.Time
	// OnAuthorized runs after each grant, with the client's name and checked host (as on the
	// consent page), so the Owner can be told.
	OnAuthorized func(ctx context.Context, userID, clientName string)
	// Logger gets what clients are not told, such as why a metadata document was refused.
	Logger *slog.Logger
	// OnGrantsChanged runs when the Owner's list of apps with access changed: a first token was
	// issued for a new approval, or a grant ended (removed, revoked by its client, reused).
	OnGrantsChanged func(ctx context.Context, userID string)
	// OnGrantRemoved runs when one grant ended while others may live on, with its public ID, so
	// its open MCP sessions can be closed.
	OnGrantRemoved func(userID, grantID string)
	// TermsURI and PolicyURI, when set, are advertised as op_tos_uri and op_policy_uri in the
	// authorization-server metadata (RFC 8414; FR-193).
	TermsURI, PolicyURI string
	// AllowedClients is the hosts whose clients may ask for access (FR-180). The zero value is
	// the default, Claude's apps only.
	AllowedClients AllowedHosts
	// Events records each app approved, refused, or removed (FR-631). Nil records nothing.
	Events *events.Recorder
}

// Server is the authorization server. zitadel/oidc (op) parses and checks the token and
// revocation requests; the relay's own code shows the sign-in and consent pages, keeps the
// codes and tokens (storage), and checks access tokens on /mcp.
type Server struct {
	cfg      Config
	op       *op.Provider
	storage  *storage
	clients  *clients
	issuer   string
	resource string
	touched  *touches
}

// New creates the server, generating the token signing key on first start.
func New(ctx context.Context, cfg Config) (*Server, error) {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	if cfg.HTTPClient == nil {
		cfg.HTTPClient = &http.Client{
			Timeout:       5 * time.Second,
			Transport:     &http.Transport{DialContext: publicOnlyDialer().DialContext, Proxy: nil},
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		}
	}
	key, err := cfg.Store.KeyOrCreate(ctx, "oauth_hmac", func() ([]byte, error) {
		b := make([]byte, 32)
		_, err := rand.Read(b)
		return b, err
	})
	if err != nil {
		return nil, err
	}
	if len(key) < 32 {
		return nil, errors.New("oauth: the token signing key is shorter than 32 bytes")
	}
	issuer := strings.TrimSuffix(cfg.Issuer.String(), "/")
	cl := &clients{st: cfg.Store, http: cfg.HTTPClient, now: cfg.Now, log: cfg.Logger, failed: map[[sha256.Size]byte]time.Time{}, allowed: cfg.AllowedClients}
	st := &storage{st: cfg.Store, clients: cl, now: cfg.Now, tokens: newHMACTokens(key)}
	provider, err := op.NewProvider(&op.Config{
		CodeMethodS256:          true,
		AuthMethodPost:          true,  // registered clients may send their secret in the form
		AuthMethodPrivateKeyJWT: false, // client assertions are refused before zitadel sees them
		GrantTypeRefreshToken:   true,
		RequestObjectSupported:  false,
		SupportedScopes:         supportedScopes,
	}, st, op.StaticIssuer(issuer),
		op.WithAllowInsecure(), // the issuer is the operator's; local checks run on http://127.0.0.1
		op.WithCrypto(opaqueCrypto{}),
	)
	if err != nil {
		return nil, err
	}
	srv := &Server{cfg: cfg, op: provider, storage: st, clients: cl, issuer: issuer, resource: issuer + "/mcp"}
	srv.touched = &touches{last: map[string]touch{}}
	st.revoked = srv.revoked // revocations report a grant that lost its access (FR-192)
	if _, err := srv.PurgeRefusedClients(ctx); err != nil {
		return nil, err
	}
	return srv, nil
}

// ResourceURL is the connector URL Claude is given.
func (s *Server) ResourceURL() string { return s.resource }

// Register mounts the OAuth endpoints.
func (s *Server) Register(mux *http.ServeMux) {
	prm := auth.ProtectedResourceMetadataHandler(&oauthex.ProtectedResourceMetadata{
		Resource:               s.resource,
		AuthorizationServers:   []string{s.issuer},
		ScopesSupported:        supportedScopes,
		BearerMethodsSupported: []string{"header"},
	})
	mux.Handle("GET /.well-known/oauth-protected-resource", prm)
	mux.Handle("GET /.well-known/oauth-protected-resource/mcp", prm)
	mux.HandleFunc("GET /.well-known/oauth-authorization-server", s.metadata)
	mux.HandleFunc("POST /register", s.clients.register)
	mux.HandleFunc("GET /authorize", s.authorize)
	mux.HandleFunc("POST /authorize", s.authorize)
	mux.HandleFunc("POST /token", s.token)
	mux.HandleFunc("POST /revoke", s.revoke)
}

func (s *Server) metadata(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	m := map[string]any{
		"issuer":                                     s.issuer,
		"authorization_endpoint":                     s.issuer + "/authorize",
		"token_endpoint":                             s.issuer + "/token",
		"revocation_endpoint":                        s.issuer + "/revoke",
		"response_types_supported":                   []string{"code"},
		"grant_types_supported":                      []string{"authorization_code", "refresh_token"},
		"code_challenge_methods_supported":           []string{"S256"},
		"token_endpoint_auth_methods_supported":      []string{"none", "client_secret_post", "client_secret_basic"},
		"revocation_endpoint_auth_methods_supported": []string{"none", "client_secret_post", "client_secret_basic"},
		"client_id_metadata_document_supported":      true,
		"scopes_supported":                           supportedScopes,
		// RFC 9207: every authorization response carries iss (see redirectBack).
		"authorization_response_iss_parameter_supported": true,
	}
	if s.cfg.TermsURI != "" { // FR-193: only where the operator published the documents
		m["op_tos_uri"] = s.cfg.TermsURI
	}
	if s.cfg.PolicyURI != "" {
		m["op_policy_uri"] = s.cfg.PolicyURI
	}
	if s.cfg.AllowedClients.any {
		m["registration_endpoint"] = s.issuer + "/register"
	} else {
		// FR-182: no registration, so no client has a secret. "none" and
		// client_id_metadata_document_supported are what make Claude use a metadata document.
		m["token_endpoint_auth_methods_supported"] = []string{"none"}
		m["revocation_endpoint_auth_methods_supported"] = []string{"none"}
	}
	_ = json.NewEncoder(w).Encode(m)
}

// Protect requires a valid access token with scope "mcp". A request without one gets exactly
// the 401 the contract specifies, so Claude can discover how to sign in.
func (s *Server) Protect(h http.Handler) http.Handler {
	challenge := `Bearer resource_metadata="` + s.issuer + `/.well-known/oauth-protected-resource/mcp", scope="mcp offline_access"`
	protected := auth.RequireBearerToken(s.verify, &auth.RequireBearerTokenOptions{
		ResourceMetadataURL: s.issuer + "/.well-known/oauth-protected-resource/mcp",
		Scopes:              []string{"mcp"},
	})(h)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") == "" {
			events.Note(r.Context(), "no token")
		}
		protected.ServeHTTP(&challengeWriter{ResponseWriter: w, challenge: challenge}, r)
	})
}

// challengeWriter replaces the SDK's WWW-Authenticate value on 401 and 403 responses.
type challengeWriter struct {
	http.ResponseWriter
	challenge string
	wrote     bool
}

func (c *challengeWriter) WriteHeader(code int) {
	if !c.wrote && (code == http.StatusUnauthorized || code == http.StatusForbidden) {
		c.Header().Set("WWW-Authenticate", c.challenge)
	}
	c.wrote = true
	c.ResponseWriter.WriteHeader(code)
}

func (c *challengeWriter) Write(b []byte) (int, error) {
	c.wrote = true
	return c.ResponseWriter.Write(b)
}

// Flush and Unwrap keep streaming responses working through the wrapper.
func (c *challengeWriter) Flush() {
	if f, ok := c.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (c *challengeWriter) Unwrap() http.ResponseWriter { return c.ResponseWriter }

// RevokeUser deletes all of the Owner's codes and tokens, for every client (FR-044). by says
// who or what removed them, for the event record.
func (s *Server) RevokeUser(ctx context.Context, userID, by string) error {
	grants, _ := s.Grants(ctx, userID)
	if err := s.cfg.Store.DeleteUserOAuth(ctx, userID); err != nil {
		return err
	}
	for _, g := range grants {
		s.cfg.Events.Record(ctx, store.Event{
			Kind: events.ClaudeRemoved, UserID: userID, Detail: eventLabel(g.Label()) + ", " + by,
		})
	}
	s.grantsChanged(ctx, userID)
	return nil
}

// eventLabel bounds an app's name for the event record.
func eventLabel(l string) string {
	if r := []rune(l); len(r) > 128 {
		return string(r[:128])
	}
	return l
}

// ClientName is the display name of a client the Owner approved, with the host the relay
// checked, e.g. "Claude (claude.ai)".
func (s *Server) ClientName(ctx context.Context, clientID string) string {
	if c, err := s.clients.get(ctx, clientID); err == nil {
		return label(c, nil)
	}
	return clientID
}

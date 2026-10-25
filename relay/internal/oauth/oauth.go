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
	"github.com/ory/fosite"
	"github.com/ory/fosite/compose"
	"golang.org/x/net/idna"

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
func verifiedHosts(cl fosite.Client, redirect *url.URL) []string {
	if isCIMD(cl.GetID()) {
		if u, err := url.Parse(cl.GetID()); err == nil {
			return []string{displayHost(u.Hostname())}
		}
	}
	if redirect != nil && redirect.Hostname() != "" {
		return []string{displayHost(redirect.Hostname())}
	}
	var out []string
	for _, raw := range cl.GetRedirectURIs() {
		if u, err := url.Parse(raw); err == nil && u.Hostname() != "" && !slices.Contains(out, displayHost(u.Hostname())) {
			out = append(out, displayHost(u.Hostname()))
		}
	}
	return out
}

// label names an approved client for the Owner.
func label(cl fosite.Client, redirect *url.URL) string {
	name := ""
	if c, ok := cl.(*client); ok {
		name = c.Name
	}
	return clientLabel(name, strings.Join(verifiedHosts(cl, redirect), ", "))
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
}

// Server is the authorization server.
type Server struct {
	cfg      Config
	provider fosite.OAuth2Provider
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
	issuer := strings.TrimSuffix(cfg.Issuer.String(), "/")
	fc := &fosite.Config{
		AccessTokenLifespan:            time.Hour,
		RefreshTokenLifespan:           90 * 24 * time.Hour,
		AuthorizeCodeLifespan:          time.Minute,
		GlobalSecret:                   key,
		EnforcePKCE:                    true,
		EnforcePKCEForPublicClients:    true,
		EnablePKCEPlainChallengeMethod: false,
		ScopeStrategy:                  fosite.ExactScopeStrategy,
		AudienceMatchingStrategy:       fosite.DefaultAudienceMatchingStrategy,
		ClientSecretsHasher:            sha256Hasher{},
		TokenURL:                       issuer + "/token",
		RefreshTokenScopes:             []string{"offline_access"},
		SendDebugMessagesToClients:     false,
	}
	cl := &clients{st: cfg.Store, http: cfg.HTTPClient, now: cfg.Now, log: cfg.Logger, failed: map[[sha256.Size]byte]time.Time{}}
	srv := &Server{cfg: cfg, clients: cl, issuer: issuer, resource: issuer + "/mcp", touched: &touches{last: map[string]touch{}}}
	st := &storage{st: cfg.Store, clients: cl, now: cfg.Now, revoked: srv.revoked}
	provider := compose.Compose(fc, st, compose.NewOAuth2HMACStrategy(fc),
		compose.OAuth2AuthorizeExplicitFactory,
		compose.OAuth2RefreshTokenGrantFactory,
		compose.OAuth2TokenRevocationFactory,
		compose.OAuth2TokenIntrospectionFactory,
		compose.OAuth2PKCEFactory,
	)
	srv.provider = provider
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
	md := map[string]any{
		"issuer":                                     s.issuer,
		"authorization_endpoint":                     s.issuer + "/authorize",
		"token_endpoint":                             s.issuer + "/token",
		"registration_endpoint":                      s.issuer + "/register",
		"revocation_endpoint":                        s.issuer + "/revoke",
		"response_types_supported":                   []string{"code"},
		"grant_types_supported":                      []string{"authorization_code", "refresh_token"},
		"code_challenge_methods_supported":           []string{"S256"},
		"token_endpoint_auth_methods_supported":      []string{"none", "client_secret_post", "client_secret_basic"},
		"revocation_endpoint_auth_methods_supported": []string{"none", "client_secret_post", "client_secret_basic"},
		"client_id_metadata_document_supported":      true,
		"scopes_supported":                           supportedScopes,
		// RFC 9207: every authorization response carries iss (see issWriter).
		"authorization_response_iss_parameter_supported": true,
	}
	if s.cfg.TermsURI != "" {
		md["op_tos_uri"] = s.cfg.TermsURI
	}
	if s.cfg.PolicyURI != "" {
		md["op_policy_uri"] = s.cfg.PolicyURI
	}
	_ = json.NewEncoder(w).Encode(md)
}

// issWriter adds the RFC 9207 "iss" parameter to the redirect fosite writes back to the client,
// for codes and errors alike (fosite 0.49 has no support for it). A response that isn't a
// redirect (an error shown in the browser because the client or redirect URI is unknown) is left
// as it is.
type issWriter struct {
	http.ResponseWriter
	issuer string
	wrote  bool
}

func (w *issWriter) WriteHeader(code int) {
	if !w.wrote {
		w.wrote = true
		if loc := w.Header().Get("Location"); loc != "" && code >= 300 && code < 400 {
			if u, err := url.Parse(loc); err == nil {
				q := u.Query()
				q.Set("iss", w.issuer)
				u.RawQuery = q.Encode()
				w.Header().Set("Location", u.String())
			}
		}
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *issWriter) Write(b []byte) (int, error) {
	if !w.wrote {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(b)
}

func (s *Server) writeAuthorizeError(ctx context.Context, w http.ResponseWriter, ar fosite.AuthorizeRequester, err error) {
	s.provider.WriteAuthorizeError(ctx, &issWriter{ResponseWriter: w, issuer: s.issuer}, ar, err)
}

func newSession(subject string) *fosite.DefaultSession {
	return &fosite.DefaultSession{Subject: subject, ExpiresAt: map[fosite.TokenType]time.Time{}}
}

func (s *Server) authorize(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	ctx = withRequestedRedirect(ctx, r.Form.Get("redirect_uri"))
	ar, err := s.provider.NewAuthorizeRequest(ctx, r)
	if err != nil {
		s.writeAuthorizeError(ctx, w, ar, err)
		return
	}
	// RFC 8707: a resource indicator, if given, must name this relay's MCP endpoint.
	if res := r.Form.Get("resource"); res != "" && strings.TrimSuffix(res, "/") != s.resource {
		s.writeAuthorizeError(ctx, w, ar, fosite.ErrInvalidRequest.WithHint("Unknown resource."))
		return
	}
	userID, ok := s.cfg.Auth.CurrentUser(r)
	if !ok {
		s.cfg.Auth.SignIn(w, r)
		return
	}
	// Consent is asked every time (FR-049a): only the Owner's Allow, posted from the consent page
	// with its CSRF token, issues a code. Nothing is remembered, so a program on the Owner's
	// computer posing as an approved client (a loopback redirect on any port) gets no code
	// without the Owner seeing the page (RFC 8252 §8.6).
	if r.Method != http.MethodPost {
		s.cfg.Auth.Consent(w, r, consentFor(ar))
		return
	}
	if !s.cfg.Auth.ValidCSRF(r) {
		http.Error(w, "This form expired. Go back and try again.", http.StatusForbidden)
		return
	}
	if r.PostForm.Get("decision") != "allow" {
		s.writeAuthorizeError(ctx, w, ar, fosite.ErrAccessDenied.WithHint("The Owner declined."))
		return
	}
	for _, sc := range grantable(ar.GetRequestedScopes()) {
		ar.GrantScope(sc)
	}
	resp, err := s.provider.NewAuthorizeResponse(ctx, ar, newSession(userID))
	if err != nil {
		s.writeAuthorizeError(ctx, w, ar, err)
		return
	}
	// The approval is recorded before its code leaves, so every token has a grant to be listed
	// and removed by (FR-190).
	if err := s.recordGrant(ctx, ar, userID); err != nil {
		s.cfg.Logger.Error("record grant", "err", err)
		s.writeAuthorizeError(ctx, w, ar, fosite.ErrServerError)
		return
	}
	if s.cfg.OnAuthorized != nil {
		s.cfg.OnAuthorized(ctx, userID, label(ar.GetClient(), ar.GetRedirectURI()))
	}
	s.provider.WriteAuthorizeResponse(ctx, &issWriter{ResponseWriter: w, issuer: s.issuer}, ar, resp)
}

// grantable returns the requested scopes the relay grants; "mcp" is always granted.
func grantable(requested []string) []string {
	out := []string{"mcp"}
	if slices.Contains(requested, "offline_access") {
		out = append(out, "offline_access")
	}
	return out
}

func (s *Server) token(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	ar, err := s.provider.NewAccessRequest(ctx, r, newSession(""))
	if err != nil {
		s.provider.WriteAccessError(ctx, w, ar, err)
		return
	}
	resp, err := s.provider.NewAccessResponse(ctx, ar)
	if err != nil {
		// The grant ended while its tokens were being written: another exchange used the same
		// code (storage.InvalidateAuthorizeCodeSession), or the grant was revoked or removed
		// (the store refuses the token). That is the client's grant being invalid, not a server
		// error, which is what fosite makes of any storage failure.
		if grantEnded(err) {
			err = fosite.ErrInvalidGrant.WithHint("The authorization code or token is no longer valid.")
		}
		s.provider.WriteAccessError(ctx, w, ar, err)
		return
	}
	// A redeemed code is a new app with access: the Owner's Mac gets the new list (FR-192).
	if ar.GetGrantTypes().ExactOne("authorization_code") {
		if sess, ok := ar.GetSession().(*fosite.DefaultSession); ok && sess.Subject != "" {
			s.grantsChanged(ctx, sess.Subject)
		}
	}
	s.provider.WriteAccessResponse(ctx, w, ar, resp)
}

func grantEnded(err error) bool {
	if errors.Is(err, fosite.ErrInvalidatedAuthorizeCode) {
		return true
	}
	var rfc *fosite.RFC6749Error
	return errors.As(err, &rfc) && rfc.ErrorField == fosite.ErrServerError.ErrorField && errors.Is(rfc.Unwrap(), fosite.ErrNotFound)
}

func (s *Server) revoke(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	s.provider.WriteRevocationResponse(ctx, w, s.provider.NewRevocationRequest(ctx, r))
}

// verify maps an access token to its Owner for the MCP SDK. fosite's introspection falls back
// to refresh tokens when the value isn't an access token; those are refused here.
func (s *Server) verify(ctx context.Context, token string, _ *http.Request) (*auth.TokenInfo, error) {
	use, ar, err := s.provider.IntrospectToken(ctx, token, fosite.AccessToken, newSession(""))
	if err != nil {
		if errors.Is(err, fosite.ErrServerError) {
			return nil, err
		}
		return nil, auth.ErrInvalidToken
	}
	if use != fosite.AccessToken {
		return nil, auth.ErrInvalidToken
	}
	sess, ok := ar.GetSession().(*fosite.DefaultSession)
	if !ok || sess.Subject == "" {
		return nil, auth.ErrInvalidToken
	}
	// A suspended account's tokens are deleted with the suspension; this also covers one that
	// slipped in beside it (FR-196).
	if u, err := s.cfg.Store.User(ctx, sess.Subject); err != nil || !u.SuspendedAt.IsZero() {
		return nil, auth.ErrInvalidToken
	}
	info := &auth.TokenInfo{
		UserID:     sess.Subject,
		Scopes:     ar.GetGrantedScopes(),
		Expiration: sess.GetExpiresAt(fosite.AccessToken),
	}
	if grantID := s.used(ctx, ar.GetID()); grantID != "" {
		info.Extra = map[string]any{GrantExtra: grantID}
	}
	return info, nil
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

// RevokeUser deletes all of the Owner's codes and tokens, for every client (FR-044).
func (s *Server) RevokeUser(ctx context.Context, userID string) error {
	if err := s.cfg.Store.DeleteUserOAuth(ctx, userID); err != nil {
		return err
	}
	s.grantsChanged(ctx, userID)
	return nil
}

// ClientName is the display name of a client the Owner approved, with the host the relay
// checked, e.g. "Claude (claude.ai)".
func (s *Server) ClientName(ctx context.Context, clientID string) string {
	if c, err := s.clients.get(ctx, clientID); err == nil {
		return label(c, nil)
	}
	return clientID
}

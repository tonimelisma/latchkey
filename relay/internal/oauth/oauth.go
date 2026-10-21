// Package oauth is the relay's OAuth 2.1 authorization server for Claude (plan D4,
// contracts/mcp-surface.md): discovery metadata, client registration (CIMD and DCR),
// authorization code with PKCE S256, refresh rotation, revocation, and the bearer check on /mcp.
package oauth

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/auth"
	"github.com/modelcontextprotocol/go-sdk/oauthex"
	"github.com/ory/fosite"
	"github.com/ory/fosite/compose"

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
	ClientName   string
	RedirectHost string
}

// Config configures the server.
type Config struct {
	Issuer *url.URL // the relay's public origin
	Store  *store.Store
	Auth   Authenticator
	// HTTPClient fetches client metadata documents. Default: refuses private addresses.
	HTTPClient *http.Client
	Now        func() time.Time
}

// Server is the authorization server.
type Server struct {
	cfg      Config
	provider fosite.OAuth2Provider
	clients  *clients
	issuer   string
	resource string
}

// New creates the server, generating the token signing key on first start.
func New(ctx context.Context, cfg Config) (*Server, error) {
	if cfg.Now == nil {
		cfg.Now = time.Now
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
	cl := &clients{st: cfg.Store, http: cfg.HTTPClient, now: cfg.Now}
	st := &storage{st: cfg.Store, clients: cl, now: cfg.Now}
	provider := compose.Compose(fc, st, compose.NewOAuth2HMACStrategy(fc),
		compose.OAuth2AuthorizeExplicitFactory,
		compose.OAuth2RefreshTokenGrantFactory,
		compose.OAuth2TokenRevocationFactory,
		compose.OAuth2TokenIntrospectionFactory,
		compose.OAuth2PKCEFactory,
	)
	return &Server{cfg: cfg, provider: provider, clients: cl, issuer: issuer, resource: issuer + "/mcp"}, nil
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
	_ = json.NewEncoder(w).Encode(map[string]any{
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
	})
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
		s.provider.WriteAuthorizeError(ctx, w, ar, err)
		return
	}
	// RFC 8707: a resource indicator, if given, must name this relay's MCP endpoint.
	if res := r.Form.Get("resource"); res != "" && strings.TrimSuffix(res, "/") != s.resource {
		s.provider.WriteAuthorizeError(ctx, w, ar, fosite.ErrInvalidRequest.WithHint("Unknown resource."))
		return
	}
	userID, ok := s.cfg.Auth.CurrentUser(r)
	if !ok {
		s.cfg.Auth.SignIn(w, r)
		return
	}
	scopes := grantable(ar.GetRequestedScopes())
	approved := false
	if r.Method == http.MethodPost {
		if !s.cfg.Auth.ValidCSRF(r) {
			http.Error(w, "This form expired. Go back and try again.", http.StatusForbidden)
			return
		}
		if r.PostForm.Get("decision") != "allow" {
			s.provider.WriteAuthorizeError(ctx, w, ar, fosite.ErrAccessDenied.WithHint("The Owner declined."))
			return
		}
		approved = true
	} else if prior, err := s.cfg.Store.Consent(ctx, userID, ar.GetClient().GetID()); err == nil &&
		covers(strings.Fields(prior), scopes) {
		approved = true // FR-049
	}
	if !approved {
		c := ConsentRequest{RedirectHost: ar.GetRedirectURI().Host}
		if cl, ok := ar.GetClient().(*client); ok {
			c.ClientName = cl.Name
		}
		s.cfg.Auth.Consent(w, r, c)
		return
	}
	for _, sc := range scopes {
		ar.GrantScope(sc)
	}
	resp, err := s.provider.NewAuthorizeResponse(ctx, ar, newSession(userID))
	if err != nil {
		s.provider.WriteAuthorizeError(ctx, w, ar, err)
		return
	}
	if err := s.cfg.Store.PutConsent(ctx, userID, ar.GetClient().GetID(), strings.Join(scopes, " "), s.cfg.Now()); err != nil {
		http.Error(w, "server error", http.StatusInternalServerError)
		return
	}
	s.provider.WriteAuthorizeResponse(ctx, w, ar, resp)
}

// grantable returns the requested scopes the relay grants; "mcp" is always granted.
func grantable(requested []string) []string {
	out := []string{"mcp"}
	if slices.Contains(requested, "offline_access") {
		out = append(out, "offline_access")
	}
	return out
}

func covers(have, want []string) bool {
	for _, w := range want {
		if !slices.Contains(have, w) {
			return false
		}
	}
	return true
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
		s.provider.WriteAccessError(ctx, w, ar, err)
		return
	}
	s.provider.WriteAccessResponse(ctx, w, ar, resp)
}

func (s *Server) revoke(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	s.provider.WriteRevocationResponse(ctx, w, s.provider.NewRevocationRequest(ctx, r))
}

// verify maps an access token to its Owner for the MCP SDK.
func (s *Server) verify(ctx context.Context, token string, _ *http.Request) (*auth.TokenInfo, error) {
	_, ar, err := s.provider.IntrospectToken(ctx, token, fosite.AccessToken, newSession(""))
	if err != nil {
		if errors.Is(err, fosite.ErrServerError) {
			return nil, err
		}
		return nil, auth.ErrInvalidToken
	}
	sess, ok := ar.GetSession().(*fosite.DefaultSession)
	if !ok || sess.Subject == "" {
		return nil, auth.ErrInvalidToken
	}
	if _, err := s.cfg.Store.User(ctx, sess.Subject); err != nil {
		return nil, auth.ErrInvalidToken
	}
	return &auth.TokenInfo{
		UserID:     sess.Subject,
		Scopes:     ar.GetGrantedScopes(),
		Expiration: sess.GetExpiresAt(fosite.AccessToken),
	}, nil
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

// RevokeUser deletes all of the Owner's tokens and remembered approvals (FR-044).
func (s *Server) RevokeUser(ctx context.Context, userID string) error {
	return s.cfg.Store.DeleteUserOAuth(ctx, userID)
}

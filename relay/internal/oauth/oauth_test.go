package oauth_test

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/auth"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/modelcontextprotocol/go-sdk/oauthex"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/hub"
	"github.com/tonimelisma/latchkey/relay/internal/mcpserver"
	"github.com/tonimelisma/latchkey/relay/internal/oauth"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// fakeAuth signs in whoever carries the "u" cookie and approves with CSRF token "ok".
type fakeAuth struct {
	mu       sync.Mutex
	consents []oauth.ConsentRequest
}

func (f *fakeAuth) CurrentUser(r *http.Request) (string, bool) {
	c, err := r.Cookie("u")
	if err != nil {
		return "", false
	}
	return c.Value, true
}

func (f *fakeAuth) SignIn(w http.ResponseWriter, r *http.Request) {
	http.Redirect(w, r, "/signin?next="+url.QueryEscape(r.URL.RequestURI()), http.StatusFound)
}

func (f *fakeAuth) Consent(w http.ResponseWriter, _ *http.Request, c oauth.ConsentRequest) {
	f.mu.Lock()
	f.consents = append(f.consents, c)
	f.mu.Unlock()
	_, _ = io.WriteString(w, "CONSENT "+c.ClientName+" "+c.RedirectHost)
}

func (f *fakeAuth) ValidCSRF(r *http.Request) bool { return r.PostForm.Get("csrf") == "ok" }

func (f *fakeAuth) consentCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.consents)
}

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *clock) advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

type env struct {
	t      *testing.T
	store  *store.Store
	oauth  *oauth.Server
	auth   *fakeAuth
	clock  *clock
	srv    *httptest.Server
	cimd   *httptest.Server
	userID string
}

func setup(t *testing.T) *env {
	t.Helper()
	ctx := context.Background()
	st, err := store.Open(ctx, filepath.Join(t.TempDir(), "relay.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = st.Close() })
	e := &env{t: t, store: st, auth: &fakeAuth{}, clock: &clock{t: time.Now()}}

	// A client metadata document server, as Claude hosts one (served over TLS).
	e.cimd = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"client_id":                  "https://" + r.Host + r.URL.Path,
			"client_name":                "Claude",
			"redirect_uris":              []string{"http://localhost:7777/callback"},
			"token_endpoint_auth_method": "none",
		})
	}))
	t.Cleanup(e.cimd.Close)

	mux := http.NewServeMux()
	e.srv = httptest.NewServer(mux)
	t.Cleanup(e.srv.Close)
	issuer, _ := url.Parse(e.srv.URL)
	e.oauth, err = oauth.New(ctx, oauth.Config{
		Issuer: issuer, Store: st, Auth: e.auth, HTTPClient: e.cimd.Client(), Now: e.clock.now,
	})
	require.NoError(t, err)
	e.oauth.Register(mux)

	var ms *mcpserver.Server
	h := hub.New(st, hub.Config{OnToolsChanged: func(id string) { ms.ToolsChanged(id) }})
	ms = mcpserver.New(st, h, mcpserver.Options{})
	mux.Handle("/mcp", e.oauth.Protect(ms))

	u, err := st.CreateUser(ctx, "owner@example.com", time.Now())
	require.NoError(t, err)
	e.userID = u.ID
	return e
}

func ctxT(t *testing.T) context.Context {
	c, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	t.Cleanup(cancel)
	return c
}

func noRedirect() *http.Client {
	return &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}

func (e *env) do(method, path string, body io.Reader, contentType string, signedIn bool) *http.Response {
	e.t.Helper()
	target := path
	if !strings.HasPrefix(path, "http") {
		target = e.srv.URL + path
	}
	req, err := http.NewRequestWithContext(ctxT(e.t), method, target, body)
	require.NoError(e.t, err)
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	if signedIn {
		req.AddCookie(&http.Cookie{Name: "u", Value: e.userID})
	}
	resp, err := noRedirect().Do(req)
	require.NoError(e.t, err)
	e.t.Cleanup(func() { _ = resp.Body.Close() })
	return resp
}

func decode(t *testing.T, resp *http.Response) map[string]any {
	t.Helper()
	var m map[string]any
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&m))
	return m
}

// fetcher completes /authorize in a "browser" signed in as the Owner, approving if asked.
func (e *env) fetcher(ctx context.Context, args *auth.AuthorizationArgs) (*auth.AuthorizationResult, error) {
	resp := e.do(http.MethodGet, args.URL, nil, "", true)
	if resp.StatusCode == http.StatusOK {
		resp = e.do(http.MethodPost, args.URL, strings.NewReader("decision=allow&csrf=ok"), "application/x-www-form-urlencoded", true)
	}
	loc, err := url.Parse(resp.Header.Get("Location"))
	if err != nil {
		return nil, err
	}
	q := loc.Query()
	return &auth.AuthorizationResult{Code: q.Get("code"), State: q.Get("state"), Iss: q.Get("iss")}, nil
}

// connect is a real MCP client doing OAuth the way Claude does.
func (e *env) connect(cfg *auth.AuthorizationCodeHandlerConfig) *mcp.ClientSession {
	e.t.Helper()
	cfg.AuthorizationCodeFetcher = e.fetcher
	cfg.RequestRefreshToken = true
	h, err := auth.NewAuthorizationCodeHandler(cfg)
	require.NoError(e.t, err)
	c := mcp.NewClient(&mcp.Implementation{Name: "claude-test", Version: "1"}, nil)
	cs, err := c.Connect(ctxT(e.t), &mcp.StreamableClientTransport{
		Endpoint: e.srv.URL + "/mcp", OAuthHandler: h, MaxRetries: -1,
	}, &mcp.ClientSessionOptions{ProtocolVersion: "2025-11-25"})
	require.NoError(e.t, err)
	e.t.Cleanup(func() { _ = cs.Close() })
	return cs
}

func TestUnauthenticatedChallenge(t *testing.T) {
	e := setup(t)
	resp := e.do(http.MethodPost, "/mcp", strings.NewReader(`{}`), "application/json", false)
	assert.Equal(t, http.StatusUnauthorized, resp.StatusCode)
	assert.Equal(t,
		`Bearer resource_metadata="`+e.srv.URL+`/.well-known/oauth-protected-resource/mcp", scope="mcp offline_access"`,
		resp.Header.Get("WWW-Authenticate"))
}

func TestProtectedResourceMetadata(t *testing.T) {
	e := setup(t)
	for _, p := range []string{"/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp"} {
		m := decode(t, e.do(http.MethodGet, p, nil, "", false))
		assert.Equal(t, e.srv.URL+"/mcp", m["resource"], "resource must equal the connector URL")
		assert.Equal(t, []any{e.srv.URL}, m["authorization_servers"])
		assert.Equal(t, []any{"mcp", "offline_access"}, m["scopes_supported"])
		assert.Equal(t, []any{"header"}, m["bearer_methods_supported"])
	}
}

func TestAuthorizationServerMetadata(t *testing.T) {
	e := setup(t)
	m := decode(t, e.do(http.MethodGet, "/.well-known/oauth-authorization-server", nil, "", false))
	want := map[string]any{
		"issuer":                                e.srv.URL,
		"authorization_endpoint":                e.srv.URL + "/authorize",
		"token_endpoint":                        e.srv.URL + "/token",
		"registration_endpoint":                 e.srv.URL + "/register",
		"revocation_endpoint":                   e.srv.URL + "/revoke",
		"response_types_supported":              []any{"code"},
		"grant_types_supported":                 []any{"authorization_code", "refresh_token"},
		"code_challenge_methods_supported":      []any{"S256"},
		"token_endpoint_auth_methods_supported": []any{"none", "client_secret_post", "client_secret_basic"},
		"client_id_metadata_document_supported": true,
		"scopes_supported":                      []any{"mcp", "offline_access"},
	}
	for k, v := range want {
		assert.Equal(t, v, m[k], k)
	}
}

func TestDCRFlowWithRealClient(t *testing.T) {
	e := setup(t)
	cs := e.connect(&auth.AuthorizationCodeHandlerConfig{
		RedirectURL: "http://localhost:51234/callback",
		DynamicClientRegistrationConfig: &auth.DynamicClientRegistrationConfig{Metadata: &oauthex.ClientRegistrationMetadata{
			ClientName: "Claude Code", RedirectURIs: []string{"http://localhost:51234/callback"}, TokenEndpointAuthMethod: "none",
		}},
	})
	res, err := cs.ListTools(ctxT(t), nil)
	require.NoError(t, err)
	assert.Empty(t, res.Tools, "signed in; no Mac paired yet")
	require.Equal(t, 1, e.auth.consentCount())
	assert.Equal(t, oauth.ConsentRequest{ClientName: "Claude Code", RedirectHost: "localhost:51234"}, e.auth.consents[0])
}

func TestCIMDFlowWithRealClient(t *testing.T) {
	e := setup(t)
	cs := e.connect(&auth.AuthorizationCodeHandlerConfig{
		RedirectURL:                    "http://localhost:7777/callback",
		ClientIDMetadataDocumentConfig: &auth.ClientIDMetadataDocumentConfig{URL: e.cimd.URL + "/oauth/client.json"},
	})
	_, err := cs.ListTools(ctxT(t), nil)
	require.NoError(t, err, "signed in through the metadata document")
	require.Equal(t, 1, e.auth.consentCount())
	assert.Equal(t, "Claude", e.auth.consents[0].ClientName)
}

// manual flow helpers

type pkce struct{ verifier, challenge string }

func newPKCE() pkce {
	v := strings.Repeat("v", 50)
	h := sha256.Sum256([]byte(v))
	return pkce{v, base64.RawURLEncoding.EncodeToString(h[:])}
}

func (e *env) register(redirects ...string) string {
	e.t.Helper()
	body, _ := json.Marshal(map[string]any{"client_name": "Claude", "redirect_uris": redirects, "token_endpoint_auth_method": "none"})
	resp := e.do(http.MethodPost, "/register", strings.NewReader(string(body)), "application/json", false)
	require.Equal(e.t, http.StatusCreated, resp.StatusCode)
	m := decode(e.t, resp)
	id, _ := m["client_id"].(string)
	require.NotEmpty(e.t, id)
	return id
}

func authorizeURL(clientID, redirect string, p *pkce, extra url.Values) string {
	q := url.Values{
		"response_type": {"code"}, "client_id": {clientID}, "redirect_uri": {redirect},
		"scope": {"mcp offline_access"}, "state": {"state-123456789"},
	}
	if p != nil {
		q.Set("code_challenge", p.challenge)
		q.Set("code_challenge_method", "S256")
	}
	for k, v := range extra {
		q[k] = v
	}
	return "/authorize?" + q.Encode()
}

// approve walks the browser through /authorize and returns the redirect it ends at.
func (e *env) approve(path string) *url.URL {
	e.t.Helper()
	resp := e.do(http.MethodGet, path, nil, "", true)
	if resp.StatusCode == http.StatusOK {
		resp = e.do(http.MethodPost, path, strings.NewReader("decision=allow&csrf=ok"), "application/x-www-form-urlencoded", true)
	}
	require.Contains(e.t, []int{http.StatusFound, http.StatusSeeOther}, resp.StatusCode)
	loc, err := url.Parse(resp.Header.Get("Location"))
	require.NoError(e.t, err)
	return loc
}

func (e *env) tokenRequest(form url.Values) (*http.Response, map[string]any) {
	e.t.Helper()
	resp := e.do(http.MethodPost, "/token", strings.NewReader(form.Encode()), "application/x-www-form-urlencoded", false)
	return resp, decode(e.t, resp)
}

func (e *env) tokens(clientID string) (access, refresh string) {
	e.t.Helper()
	const redirect = "https://claude.ai/api/mcp/auth_callback"
	p := newPKCE()
	loc := e.approve(authorizeURL(clientID, redirect, &p, nil))
	code := loc.Query().Get("code")
	require.NotEmpty(e.t, code, loc.String())
	resp, m := e.tokenRequest(url.Values{
		"grant_type": {"authorization_code"}, "code": {code}, "redirect_uri": {redirect},
		"client_id": {clientID}, "code_verifier": {p.verifier},
	})
	require.Equal(e.t, http.StatusOK, resp.StatusCode, m)
	access, _ = m["access_token"].(string)
	refresh, _ = m["refresh_token"].(string)
	require.NotEmpty(e.t, access)
	require.NotEmpty(e.t, refresh)
	return access, refresh
}

func (e *env) mcpStatus(access string) int {
	e.t.Helper()
	req, err := http.NewRequestWithContext(ctxT(e.t), http.MethodPost, e.srv.URL+"/mcp",
		strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`))
	require.NoError(e.t, err)
	req.Header.Set("Authorization", "Bearer "+access)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	resp, err := http.DefaultClient.Do(req)
	require.NoError(e.t, err)
	_ = resp.Body.Close()
	return resp.StatusCode
}

func TestPKCERequired(t *testing.T) {
	e := setup(t)
	id := e.register("https://claude.ai/api/mcp/auth_callback")
	loc := e.approve(authorizeURL(id, "https://claude.ai/api/mcp/auth_callback", nil, nil))
	assert.Equal(t, "invalid_request", loc.Query().Get("error"), "missing PKCE")
	assert.Empty(t, loc.Query().Get("code"))

	p := newPKCE()
	loc = e.approve(authorizeURL(id, "https://claude.ai/api/mcp/auth_callback", &p, url.Values{"code_challenge_method": {"plain"}}))
	assert.NotEmpty(t, loc.Query().Get("error"), "plain PKCE")
	assert.Empty(t, loc.Query().Get("code"))
}

func TestRedirectURIRules(t *testing.T) {
	e := setup(t)
	id := e.register("http://localhost:1111/callback", "http://127.0.0.1:1111/callback", "https://claude.ai/api/mcp/auth_callback")

	for _, ok := range []string{
		"http://localhost:2222/callback", // Claude Code picks a new port
		"http://127.0.0.1:3333/callback",
		"https://claude.ai/api/mcp/auth_callback",
	} {
		p := newPKCE()
		loc := e.approve(authorizeURL(id, ok, &p, nil))
		assert.NotEmpty(t, loc.Query().Get("code"), ok)
		assert.Equal(t, loc.Host, mustParse(ok).Host)
	}

	for _, bad := range []string{
		"https://evil.example/callback",
		"http://localhost:2222/other",
		"https://claude.ai/api/mcp/auth_callback/extra",
	} {
		p := newPKCE()
		resp := e.do(http.MethodGet, authorizeURL(id, bad, &p, nil), nil, "", true)
		assert.Equal(t, http.StatusBadRequest, resp.StatusCode, "%s must not be redirected to", bad)
	}

	body := `{"redirect_uris":["http://evil.example/callback"],"token_endpoint_auth_method":"none"}`
	resp := e.do(http.MethodPost, "/register", strings.NewReader(body), "application/json", false)
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode, "plain http is only for loopback")
	assert.Equal(t, "invalid_redirect_uri", decode(t, resp)["error"])
}

func mustParse(s string) *url.URL {
	u, err := url.Parse(s)
	if err != nil {
		panic(err)
	}
	return u
}

func TestSignInRequired(t *testing.T) {
	e := setup(t)
	id := e.register("https://claude.ai/api/mcp/auth_callback")
	p := newPKCE()
	resp := e.do(http.MethodGet, authorizeURL(id, "https://claude.ai/api/mcp/auth_callback", &p, nil), nil, "", false)
	assert.Equal(t, http.StatusFound, resp.StatusCode)
	assert.True(t, strings.HasPrefix(resp.Header.Get("Location"), "/signin?next="))
}

func TestDenyAndCSRF(t *testing.T) {
	e := setup(t)
	id := e.register("https://claude.ai/api/mcp/auth_callback")
	p := newPKCE()
	path := authorizeURL(id, "https://claude.ai/api/mcp/auth_callback", &p, nil)
	resp := e.do(http.MethodPost, path, strings.NewReader("decision=allow&csrf=bad"), "application/x-www-form-urlencoded", true)
	assert.Equal(t, http.StatusForbidden, resp.StatusCode)

	resp = e.do(http.MethodPost, path, strings.NewReader("decision=deny&csrf=ok"), "application/x-www-form-urlencoded", true)
	loc := mustParse(resp.Header.Get("Location"))
	assert.Equal(t, "access_denied", loc.Query().Get("error"))
}

func TestConsentRemembered(t *testing.T) {
	e := setup(t)
	id := e.register("https://claude.ai/api/mcp/auth_callback")
	e.tokens(id)
	e.tokens(id)
	assert.Equal(t, 1, e.auth.consentCount(), "FR-049: asked once per client")
}

func TestResourceIndicator(t *testing.T) {
	e := setup(t)
	id := e.register("https://claude.ai/api/mcp/auth_callback")
	p := newPKCE()
	loc := e.approve(authorizeURL(id, "https://claude.ai/api/mcp/auth_callback", &p, url.Values{"resource": {e.srv.URL + "/mcp"}}))
	assert.NotEmpty(t, loc.Query().Get("code"))
	p = newPKCE()
	loc = e.approve(authorizeURL(id, "https://claude.ai/api/mcp/auth_callback", &p, url.Values{"resource": {"https://other.example/mcp"}}))
	assert.Equal(t, "invalid_request", loc.Query().Get("error"))
}

func TestCodeIsSingleUse(t *testing.T) {
	e := setup(t)
	id := e.register("https://claude.ai/api/mcp/auth_callback")
	p := newPKCE()
	code := e.approve(authorizeURL(id, "https://claude.ai/api/mcp/auth_callback", &p, nil)).Query().Get("code")
	form := url.Values{
		"grant_type": {"authorization_code"}, "code": {code}, "redirect_uri": {"https://claude.ai/api/mcp/auth_callback"},
		"client_id": {id}, "code_verifier": {p.verifier},
	}
	resp, _ := e.tokenRequest(form)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	resp, m := e.tokenRequest(form)
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	assert.Equal(t, "invalid_grant", m["error"])

	resp, m = e.tokenRequest(url.Values{
		"grant_type": {"authorization_code"}, "code": {"nonsense"}, "redirect_uri": {"https://claude.ai/api/mcp/auth_callback"},
		"client_id": {id}, "code_verifier": {p.verifier},
	})
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	assert.Equal(t, "invalid_grant", m["error"])
}

func TestRefreshRotationAndGrace(t *testing.T) {
	e := setup(t)
	id := e.register("https://claude.ai/api/mcp/auth_callback")
	access, refresh := e.tokens(id)
	assert.Equal(t, http.StatusOK, e.mcpStatus(access))

	refreshWith := func(token string) (int, map[string]any) {
		resp, m := e.tokenRequest(url.Values{"grant_type": {"refresh_token"}, "refresh_token": {token}, "client_id": {id}})
		return resp.StatusCode, m
	}
	start := time.Now()
	code, m := refreshWith(refresh)
	assert.Less(t, time.Since(start), 2*time.Second, "token endpoint latency")
	require.Equal(t, http.StatusOK, code, m)
	newRefresh, _ := m["refresh_token"].(string)
	newAccess, _ := m["access_token"].(string)
	assert.NotEqual(t, refresh, newRefresh, "refresh tokens rotate")
	assert.Equal(t, http.StatusOK, e.mcpStatus(newAccess))

	// Within 60 s the old refresh token still works (a retry after a lost response).
	e.clock.advance(30 * time.Second)
	code, _ = refreshWith(refresh)
	assert.Equal(t, http.StatusOK, code)

	// After the grace window, reuse is refused and the whole grant is revoked.
	e.clock.advance(time.Minute)
	code, m = refreshWith(refresh)
	assert.Equal(t, http.StatusBadRequest, code)
	assert.Equal(t, "invalid_grant", m["error"])
	code, _ = refreshWith(newRefresh)
	assert.Equal(t, http.StatusBadRequest, code, "reuse detection revokes the family")
	assert.Equal(t, http.StatusUnauthorized, e.mcpStatus(newAccess))

	code, m = refreshWith("garbage.token")
	assert.Equal(t, http.StatusBadRequest, code)
	assert.Equal(t, "invalid_grant", m["error"])
}

func TestRefreshLifetimeCoversAWeekOffline(t *testing.T) {
	e := setup(t)
	id := e.register("https://claude.ai/api/mcp/auth_callback")
	p := newPKCE()
	code := e.approve(authorizeURL(id, "https://claude.ai/api/mcp/auth_callback", &p, nil)).Query().Get("code")
	resp, m := e.tokenRequest(url.Values{
		"grant_type": {"authorization_code"}, "code": {code}, "redirect_uri": {"https://claude.ai/api/mcp/auth_callback"},
		"client_id": {id}, "code_verifier": {p.verifier},
	})
	require.Equal(t, http.StatusOK, resp.StatusCode)
	assert.InDelta(t, 3600, m["expires_in"], 5, "access tokens last 1 hour")

	// The stored refresh token outlives 7 days offline (SC-07); 90 days per plan D4.
	sig := strings.SplitN(m["refresh_token"].(string), ".", 2)[1]
	row, err := e.store.OAuthRequest(ctxT(t), store.KindRefresh, sig)
	require.NoError(t, err)
	assert.WithinDuration(t, time.Now().Add(90*24*time.Hour), row.ExpiresAt, time.Hour)
}

func TestRevocation(t *testing.T) {
	e := setup(t)
	id := e.register("https://claude.ai/api/mcp/auth_callback")
	access, refresh := e.tokens(id)
	resp := e.do(http.MethodPost, "/revoke", strings.NewReader(url.Values{"token": {refresh}, "client_id": {id}}.Encode()),
		"application/x-www-form-urlencoded", false)
	assert.Equal(t, http.StatusOK, resp.StatusCode)
	assert.Equal(t, http.StatusUnauthorized, e.mcpStatus(access), "revoking the grant revokes its access tokens")
}

func TestRevokeUserAndDeletedUser(t *testing.T) {
	e := setup(t)
	id := e.register("https://claude.ai/api/mcp/auth_callback")
	access, _ := e.tokens(id)
	require.NoError(t, e.oauth.RevokeUser(ctxT(t), e.userID))
	assert.Equal(t, http.StatusUnauthorized, e.mcpStatus(access))
	e.tokens(id)
	assert.Equal(t, 2, e.auth.consentCount(), "revoking forgets the approval")

	access, _ = e.tokens(id)
	require.NoError(t, e.store.DeleteUser(ctxT(t), e.userID))
	assert.Equal(t, http.StatusUnauthorized, e.mcpStatus(access))
}

func TestTokenEndpointNeedsFormEncoding(t *testing.T) {
	e := setup(t)
	resp := e.do(http.MethodPost, "/token", strings.NewReader(`{"grant_type":"refresh_token"}`), "application/json", false)
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
}

func TestCIMDDocumentRules(t *testing.T) {
	e := setup(t)
	// A document whose client_id doesn't match its URL is refused.
	bad := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"client_id": "https://elsewhere.example/c.json", "redirect_uris": []string{"https://x.example/cb"}})
	}))
	defer bad.Close()
	p := newPKCE()
	resp := e.do(http.MethodGet, authorizeURL(bad.URL+"/c.json", "https://x.example/cb", &p, nil), nil, "", true)
	assert.Equal(t, http.StatusUnauthorized, resp.StatusCode, "invalid_client, shown in the browser")
	assert.Empty(t, resp.Header.Get("Location"), "never redirected to an unverified URI")
}

func TestCIMDFetchRefusesPrivateAddresses(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(ctx, filepath.Join(t.TempDir(), "relay.db"))
	require.NoError(t, err)
	defer func() { _ = st.Close() }()
	mux := http.NewServeMux()
	srv := httptest.NewServer(mux)
	defer srv.Close()
	issuer, _ := url.Parse(srv.URL)
	s, err := oauth.New(ctx, oauth.Config{Issuer: issuer, Store: st, Auth: &fakeAuth{}}) // default HTTP client
	require.NoError(t, err)
	s.Register(mux)
	u, err := st.CreateUser(ctx, "o@example.com", time.Now())
	require.NoError(t, err)

	cimd := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("the relay must not reach a loopback address")
	}))
	defer cimd.Close()
	p := newPKCE()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+authorizeURL(cimd.URL+"/c.json", "https://x.example/cb", &p, nil), nil)
	req.AddCookie(&http.Cookie{Name: "u", Value: u.ID})
	resp, err := noRedirect().Do(req)
	require.NoError(t, err)
	_ = resp.Body.Close()
	assert.Equal(t, http.StatusUnauthorized, resp.StatusCode, "invalid_client")
	assert.Empty(t, resp.Header.Get("Location"))
}

package oauth_test

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
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

	authorizedMu sync.Mutex
	authorized   []string // client names, in order

	// cimdFetched, if set, runs on every fetch of the metadata document, which is then served
	// uncached; the relay fetches it in the middle of a token request.
	cimdMu      sync.Mutex
	cimdFetched func()
}

// setup accepts clients from any host and dynamic registration, which most tests use.
func setup(t *testing.T) *env { return setupAllowing(t, oauth.AnyClientHost()) }

func setupAllowing(t *testing.T, allowed oauth.AllowedHosts) *env {
	t.Helper()
	return setupAt(t, filepath.Join(t.TempDir(), "relay.db"), allowed)
}

// setupAt starts a relay on the database at path, which may exist already.
func setupAt(t *testing.T, path string, allowed oauth.AllowedHosts) *env {
	t.Helper()
	ctx := context.Background()
	st, err := store.Open(ctx, path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = st.Close() })
	e := &env{t: t, store: st, auth: &fakeAuth{}, clock: &clock{t: time.Now()}}

	// A client metadata document server, as Claude hosts one (served over TLS).
	e.cimd = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		e.cimdMu.Lock()
		hook := e.cimdFetched
		e.cimdMu.Unlock()
		if hook != nil {
			w.Header().Set("Cache-Control", "no-store")
			hook()
		}
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
		AllowedClients: allowed,
		OnAuthorized: func(_ context.Context, userID, clientName string) {
			e.authorizedMu.Lock()
			defer e.authorizedMu.Unlock()
			if userID == e.userID {
				e.authorized = append(e.authorized, clientName)
			}
		},
	})
	require.NoError(t, err)
	e.oauth.Register(mux)

	var ms *mcpserver.Server
	h := hub.New(st, hub.Config{OnToolsChanged: func(id string) { ms.ToolsChanged(id) }})
	ms = mcpserver.New(st, h, mcpserver.Options{})
	mux.Handle("/mcp", e.oauth.Protect(ms))

	u, err := st.CreateUser(ctx, "owner@example.com", time.Now())
	if errors.Is(err, store.ErrConflict) { // a database from an earlier start
		u, err = st.UserByEmail(ctx, "owner@example.com")
	}
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
	assert.Equal(t, oauth.ConsentRequest{ClientName: "Claude Code", ClientHost: "localhost", RedirectHost: "localhost:51234"}, e.auth.consents[0])
	assert.Equal(t, "Claude Code (localhost)", e.auth.consents[0].Label())
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
	assert.Equal(t, "127.0.0.1", e.auth.consents[0].ClientHost, "the metadata document's host, which the relay fetched")
}

// A client's name is its own claim; the host shown next to it is what the relay checked: the
// metadata document's host, or for a registered client the host Claude's code goes to. A
// look-alike "Claude" can be told apart everywhere the name appears (security scan).
func TestClientNameShowsVerifiedHost(t *testing.T) {
	e := setup(t)
	id := e.register("https://claude-auth.attacker.example/cb")
	p := newPKCE()
	resp := e.do(http.MethodGet, authorizeURL(id, "https://claude-auth.attacker.example/cb", &p, nil), nil, "", true)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	require.Equal(t, 1, e.auth.consentCount())
	assert.Equal(t, "Claude (claude-auth.attacker.example)", e.auth.consents[0].Label())
	assert.Equal(t, "Claude (claude-auth.attacker.example)", e.oauth.ClientName(ctxT(t), id), "account page")
	e.approve(authorizeURL(id, "https://claude-auth.attacker.example/cb", &p, nil))
	e.authorizedMu.Lock()
	defer e.authorizedMu.Unlock()
	assert.Equal(t, []string{"Claude (claude-auth.attacker.example)"}, e.authorized, "the Mac's notice")
}

// manual flow helpers

// registerNamed registers a client with any name and returns its ID.
func (e *env) registerNamed(name string, redirects ...string) string {
	e.t.Helper()
	body, _ := json.Marshal(map[string]any{"client_name": name, "redirect_uris": redirects, "token_endpoint_auth_method": "none"})
	resp := e.do(http.MethodPost, "/register", strings.NewReader(string(body)), "application/json", false)
	require.Equal(e.t, http.StatusCreated, resp.StatusCode)
	id, _ := decode(e.t, resp)["client_id"].(string)
	require.NotEmpty(e.t, id)
	return id
}

// consentFor opens the consent page for a client and returns what it was asked to show.
func (e *env) consentFor(id, redirect string) oauth.ConsentRequest {
	e.t.Helper()
	p := newPKCE()
	before := e.auth.consentCount()
	resp := e.do(http.MethodGet, authorizeURL(id, redirect, &p, nil), nil, "", true)
	require.Equal(e.t, http.StatusOK, resp.StatusCode)
	require.Equal(e.t, before+1, e.auth.consentCount())
	e.auth.mu.Lock()
	defer e.auth.mu.Unlock()
	return e.auth.consents[len(e.auth.consents)-1]
}

// The name and host the Owner sees can't be made to look like another client's (review of the
// client-name fix): look-alike Unicode hosts appear in their xn-- form, a name can't carry its
// own "(host)" or control and direction characters, and it has a length limit.
func TestClientLabelResistsSpoofing(t *testing.T) {
	e := setup(t)

	homoglyph := "https://\u0441laude.ai/cb" // a Cyrillic "es" in place of the c
	c := e.consentFor(e.registerNamed("Claude", homoglyph), homoglyph)
	assert.Equal(t, "xn--laude-0ye.ai", c.ClientHost, "shown in ASCII")
	assert.NotContains(t, c.Label(), "\u0441")

	c = e.consentFor(e.registerNamed("Claude (claude.ai)\n\u202eia.edualc", "https://evil.example/cb"), "https://evil.example/cb")
	assert.Equal(t, "Claude claude.ai ia.edualc", c.ClientName, "no parentheses, newlines or direction overrides")
	assert.Equal(t, "Claude claude.ai ia.edualc (evil.example)", c.Label())

	c = e.consentFor(e.registerNamed(strings.Repeat("A", 200), "https://evil.example/cb"), "https://evil.example/cb")
	assert.LessOrEqual(t, len([]rune(c.ClientName)), 60, "a name has a length limit")

	c = e.consentFor(e.registerNamed("\u200b ()", "https://evil.example/cb"), "https://evil.example/cb")
	assert.Equal(t, "evil.example", c.Label(), "a name with nothing left shows the host alone")
}

// The account page lists every host a registered client can send codes to: it names the client,
// not one sign-in (review of the client-name fix).
func TestAccountNameListsEveryRedirectHost(t *testing.T) {
	e := setup(t)
	id := e.registerNamed("Claude", "https://claude.ai/cb", "https://evil.example/cb", "https://claude.ai/other")
	assert.Equal(t, "Claude (claude.ai, evil.example)", e.oauth.ClientName(ctxT(t), id))
}

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

// Consent is asked every time, for every client (FR-049a, RFC 8252 §8.6): a GET to /authorize
// never issues a code, however often the Owner approved that client before.
func TestConsentAskedEveryTime(t *testing.T) {
	e := setup(t)
	id := e.register("https://claude.ai/api/mcp/auth_callback")
	e.tokens(id)
	e.tokens(id)
	assert.Equal(t, 2, e.auth.consentCount(), "asked again for a client approved before")

	p := newPKCE()
	resp := e.do(http.MethodGet, authorizeURL(id, "https://claude.ai/api/mcp/auth_callback", &p, nil), nil, "", true)
	assert.Equal(t, http.StatusOK, resp.StatusCode, "the consent page, not a redirect with a code")
	assert.Empty(t, resp.Header.Get("Location"))

	// A loopback client (Claude Code) is asked again too, on any port.
	local := e.register("http://localhost:7777/callback")
	for _, port := range []string{"7777", "8123", "8123"} {
		p := newPKCE()
		resp := e.do(http.MethodGet, authorizeURL(local, "http://localhost:"+port+"/callback", &p, nil), nil, "", true)
		assert.Equal(t, http.StatusOK, resp.StatusCode, port)
		assert.Empty(t, resp.Header.Get("Location"), port)
		loc := e.approve(authorizeURL(local, "http://localhost:"+port+"/callback", &p, nil))
		assert.NotEmpty(t, loc.Query().Get("code"), port)
	}
}

func TestEveryAuthorizationIsAnnounced(t *testing.T) {
	e := setup(t)
	id := e.register("https://claude.ai/api/mcp/auth_callback")
	e.tokens(id)
	e.tokens(id)
	e.authorizedMu.Lock()
	defer e.authorizedMu.Unlock()
	assert.Equal(t, []string{"Claude (claude.ai)", "Claude (claude.ai)"}, e.authorized, "each grant")
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

// "Remove Claude's access" while a refresh is between reading its token and writing the new
// ones: the refresh must fail, and nothing it wrote may work (security scan).
func TestRevokeUserDuringRefresh(t *testing.T) {
	oauth.SetCIMDMinAge(t, 0) // every client lookup fetches the document: the test's way in
	e := setup(t)
	clientID := e.cimd.URL + "/oauth/client.json"
	const redirect = "http://localhost:7777/callback"
	e.cimdMu.Lock()
	e.cimdFetched = func() {} // uncached from the start
	e.cimdMu.Unlock()
	p := newPKCE()
	code := e.approve(authorizeURL(clientID, redirect, &p, nil)).Query().Get("code")
	resp, m := e.tokenRequest(url.Values{
		"grant_type": {"authorization_code"}, "code": {code}, "redirect_uri": {redirect},
		"client_id": {clientID}, "code_verifier": {p.verifier},
	})
	require.Equal(t, http.StatusOK, resp.StatusCode, m)
	refresh, _ := m["refresh_token"].(string)

	// The token endpoint looks the client up to authenticate it (fetch 1), then again after
	// reading the refresh token's row (fetch 2): revoke there.
	var mu sync.Mutex
	fetches := 0
	e.cimdMu.Lock()
	e.cimdFetched = func() {
		mu.Lock()
		fetches++
		n := fetches
		mu.Unlock()
		if n == 2 {
			assert.NoError(t, e.oauth.RevokeUser(context.Background(), e.userID))
		}
	}
	e.cimdMu.Unlock()
	resp, m = e.tokenRequest(url.Values{"grant_type": {"refresh_token"}, "refresh_token": {refresh}, "client_id": {clientID}})
	mu.Lock()
	require.GreaterOrEqual(t, fetches, 2, "the revocation ran inside the refresh")
	mu.Unlock()
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode, m)
	if access, ok := m["access_token"].(string); ok {
		assert.Equal(t, http.StatusUnauthorized, e.mcpStatus(access), "a token minted across the revocation must not work")
	}
	if newRefresh, ok := m["refresh_token"].(string); ok {
		resp, m = e.tokenRequest(url.Values{"grant_type": {"refresh_token"}, "refresh_token": {newRefresh}, "client_id": {clientID}})
		assert.Equal(t, http.StatusBadRequest, resp.StatusCode, m)
	}
}

// A grant revoked by marking its tokens (POST /revoke, or reuse detection) while a refresh is in
// flight: the refresh must not write fresh, unrevoked tokens for it (security review).
func TestGrantRevokedDuringRefresh(t *testing.T) {
	oauth.SetCIMDMinAge(t, 0)
	e := setup(t)
	clientID := e.cimd.URL + "/oauth/client.json"
	const redirect = "http://localhost:7777/callback"
	e.cimdMu.Lock()
	e.cimdFetched = func() {}
	e.cimdMu.Unlock()
	p := newPKCE()
	code := e.approve(authorizeURL(clientID, redirect, &p, nil)).Query().Get("code")
	resp, m := e.tokenRequest(url.Values{
		"grant_type": {"authorization_code"}, "code": {code}, "redirect_uri": {redirect},
		"client_id": {clientID}, "code_verifier": {p.verifier},
	})
	require.Equal(t, http.StatusOK, resp.StatusCode, m)
	refresh, _ := m["refresh_token"].(string)
	row, err := e.store.OAuthRequest(ctxT(t), store.KindRefresh, strings.SplitN(refresh, ".", 2)[1])
	require.NoError(t, err)

	var mu sync.Mutex
	fetches := 0
	e.cimdMu.Lock()
	e.cimdFetched = func() {
		mu.Lock()
		fetches++
		n := fetches
		mu.Unlock()
		if n == 2 { // after the refresh token's row was read, as /revoke would do it
			assert.NoError(t, e.store.RevokeOAuthRequests(context.Background(), store.KindRefresh, row.RequestID, time.Now()))
			assert.NoError(t, e.store.RevokeOAuthRequests(context.Background(), store.KindAccess, row.RequestID, time.Now()))
		}
	}
	e.cimdMu.Unlock()
	resp, m = e.tokenRequest(url.Values{"grant_type": {"refresh_token"}, "refresh_token": {refresh}, "client_id": {clientID}})
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode, m)
	if access, ok := m["access_token"].(string); ok {
		assert.Equal(t, http.StatusUnauthorized, e.mcpStatus(access), "a token minted across the revocation must not work")
	}
	if newRefresh, ok := m["refresh_token"].(string); ok {
		resp, m = e.tokenRequest(url.Values{"grant_type": {"refresh_token"}, "refresh_token": {newRefresh}, "client_id": {clientID}})
		assert.Equal(t, http.StatusBadRequest, resp.StatusCode, m)
	}
}

// A refresh token is for the token endpoint only; /mcp takes access tokens (security scan).
func TestRefreshTokenIsNotAnAccessToken(t *testing.T) {
	e := setup(t)
	id := e.register("https://claude.ai/api/mcp/auth_callback")
	access, refresh := e.tokens(id)
	assert.Equal(t, http.StatusOK, e.mcpStatus(access))
	assert.Equal(t, http.StatusUnauthorized, e.mcpStatus(refresh))
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

// RFC 9207: every redirect back to the client, with a code or with an error, names this relay
// as the issuer, and the metadata says so, so a client talking to several servers can't be fed
// another server's code (FR-097).
func TestAuthorizationResponsesNameTheIssuer(t *testing.T) {
	e := setup(t)
	m := decode(t, e.do(http.MethodGet, "/.well-known/oauth-authorization-server", nil, "", false))
	assert.Equal(t, true, m["authorization_response_iss_parameter_supported"])

	const redirect = "https://claude.ai/api/mcp/auth_callback"
	id := e.register(redirect)
	p := newPKCE()
	loc := e.approve(authorizeURL(id, redirect, &p, nil))
	require.NotEmpty(t, loc.Query().Get("code"))
	assert.Equal(t, e.srv.URL, loc.Query().Get("iss"), "with a code")
	assert.Equal(t, "state-123456789", loc.Query().Get("state"))

	resp := e.do(http.MethodPost, authorizeURL(id, redirect, &p, nil), strings.NewReader("decision=deny&csrf=ok"), "application/x-www-form-urlencoded", true)
	loc = mustParse(resp.Header.Get("Location"))
	assert.Equal(t, "access_denied", loc.Query().Get("error"))
	assert.Equal(t, e.srv.URL, loc.Query().Get("iss"), "with the Owner's no")

	loc = e.approve(authorizeURL(id, redirect, nil, nil)) // no PKCE
	assert.Equal(t, "invalid_request", loc.Query().Get("error"))
	assert.Equal(t, e.srv.URL, loc.Query().Get("iss"), "with an error")

	loc = e.approve(authorizeURL(id, redirect, &p, url.Values{"resource": {"https://other.example/mcp"}}))
	assert.Equal(t, e.srv.URL, loc.Query().Get("iss"), "with the relay's own error")

	// The sign-in redirect is the relay's own page, not an authorization response.
	resp = e.do(http.MethodGet, authorizeURL(id, redirect, &p, nil), nil, "", false)
	assert.NotContains(t, resp.Header.Get("Location"), "iss=")
}

// One code, redeemed by several requests at the same moment: at most one gets tokens, the others
// are told the code is used, and the grant ends as it does for a replay (FR-096).
func TestCodeRedeemedConcurrently(t *testing.T) {
	e := setup(t)
	const redirect = "https://claude.ai/api/mcp/auth_callback"
	id := e.register(redirect)
	for range 5 {
		p := newPKCE()
		code := e.approve(authorizeURL(id, redirect, &p, nil)).Query().Get("code")
		form := url.Values{
			"grant_type": {"authorization_code"}, "code": {code}, "redirect_uri": {redirect},
			"client_id": {id}, "code_verifier": {p.verifier},
		}
		type result struct {
			status int
			body   map[string]any
		}
		results := make(chan result, 8)
		var wg sync.WaitGroup
		for range 8 {
			wg.Go(func() {
				req, err := http.NewRequestWithContext(ctxT(t), http.MethodPost, e.srv.URL+"/token", strings.NewReader(form.Encode()))
				if err != nil {
					t.Error(err)
					return
				}
				req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
				resp, err := http.DefaultClient.Do(req)
				if err != nil {
					t.Error(err)
					return
				}
				defer func() { _ = resp.Body.Close() }()
				var m map[string]any
				_ = json.NewDecoder(resp.Body).Decode(&m)
				results <- result{resp.StatusCode, m}
			})
		}
		wg.Wait()
		close(results)
		ok := 0
		for r := range results {
			if r.status == http.StatusOK {
				ok++
				access, _ := r.body["access_token"].(string)
				assert.Equal(t, http.StatusUnauthorized, e.mcpStatus(access), "a code used twice ends its grant")
				continue
			}
			assert.NotContains(t, r.body, "access_token")
			assert.Equal(t, http.StatusBadRequest, r.status, r.body)
			assert.Equal(t, "invalid_grant", r.body["error"], "never a server error")
		}
		assert.LessOrEqual(t, ok, 1, "a code is redeemed once")
	}
}

// A name can't carry a "(host)" of its own in any script: every kind of bracket is removed, not
// only the ASCII parentheses (FR-098).
func TestClientNameLosesEveryKindOfBracket(t *testing.T) {
	e := setup(t)
	for _, name := range []string{
		"Claude \uff08claude.ai\uff09", // fullwidth parentheses
		"Claude \ufe59claude.ai\ufe5a", // small parentheses
		"Claude \u2768claude.ai\u2769", // ornament parentheses
		"Claude [claude.ai]", "Claude {claude.ai}", "Claude \u27e8claude.ai\u27e9", "Claude \u300cclaude.ai\u300d",
		"Claude \u207dclaude.ai\u207e", // superscript parentheses
		"Claude \ufd3eclaude.ai\ufd3f", // ornate parentheses (the open one is a close, and the reverse)
	} {
		c := e.consentFor(e.registerNamed(name, "https://evil.example/cb"), "https://evil.example/cb")
		assert.Equal(t, "Claude claude.ai", c.ClientName, "%q", name)
		assert.Equal(t, "Claude claude.ai (evil.example)", c.Label(), "%q", name)
	}
}

// cimdServer is a client metadata document host whose behavior a test can change.
type cimdServer struct {
	*httptest.Server
	mu           sync.Mutex
	hits         int
	fail         bool
	cacheControl string
}

func newCIMDServer(t *testing.T) *cimdServer {
	t.Helper()
	c := &cimdServer{}
	c.Server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c.mu.Lock()
		c.hits++
		fail, cc := c.fail, c.cacheControl
		c.mu.Unlock()
		if fail {
			http.Error(w, "down", http.StatusServiceUnavailable)
			return
		}
		if cc != "" {
			w.Header().Set("Cache-Control", cc)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"client_id": "https://" + r.Host + r.URL.Path, "client_name": "Claude",
			"redirect_uris": []string{"https://claude.ai/api/mcp/auth_callback"}, "token_endpoint_auth_method": "none",
		})
	}))
	t.Cleanup(c.Close)
	return c
}

func (c *cimdServer) set(fail bool, cacheControl string) {
	c.mu.Lock()
	c.fail, c.cacheControl = fail, cacheControl
	c.mu.Unlock()
}

func (c *cimdServer) fetched() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.hits
}

// authorizeStatus opens the consent page for a metadata-document client.
func (e *env) authorizeStatus(clientID string) *http.Response {
	e.t.Helper()
	p := newPKCE()
	return e.do(http.MethodGet, authorizeURL(clientID, "https://claude.ai/api/mcp/auth_callback", &p, nil), nil, "", true)
}

// A document is cached for at least five minutes whatever its host says, and when a refresh
// fails the last good copy keeps working for a week, so the outage of a client's metadata host
// doesn't cut its users off (FR-095).
func TestCIMDMinimumCacheAndStaleCopy(t *testing.T) {
	e := setup(t)
	doc := newCIMDServer(t)
	doc.set(false, "no-store, max-age=0")
	id := doc.URL + "/client.json"

	require.Equal(t, http.StatusOK, e.authorizeStatus(id).StatusCode)
	require.Equal(t, http.StatusOK, e.authorizeStatus(id).StatusCode)
	e.clock.advance(4 * time.Minute)
	require.Equal(t, http.StatusOK, e.authorizeStatus(id).StatusCode)
	assert.Equal(t, 1, doc.fetched(), "no-store still means five minutes")

	e.clock.advance(2 * time.Minute)
	require.Equal(t, http.StatusOK, e.authorizeStatus(id).StatusCode)
	assert.Equal(t, 2, doc.fetched(), "refreshed after the minimum")

	doc.set(true, "")
	e.clock.advance(6 * time.Minute)
	assert.Equal(t, http.StatusOK, e.authorizeStatus(id).StatusCode, "the host is down: the last good copy is used")
	assert.Equal(t, 3, doc.fetched())
	assert.Equal(t, http.StatusOK, e.authorizeStatus(id).StatusCode)
	assert.Equal(t, 3, doc.fetched(), "and the failing host is left alone for a few minutes")

	e.clock.advance(6 * time.Minute)
	assert.Equal(t, http.StatusOK, e.authorizeStatus(id).StatusCode)
	assert.Equal(t, 4, doc.fetched(), "then tried again")

	e.clock.advance(8 * 24 * time.Hour)
	assert.Equal(t, http.StatusUnauthorized, e.authorizeStatus(id).StatusCode, "a copy more than a week stale is not used")

	doc.set(false, "")
	e.clock.advance(6 * time.Minute)
	assert.Equal(t, http.StatusOK, e.authorizeStatus(id).StatusCode, "back again")
}

// A document that can't be fetched is not fetched again for a few minutes, and the error the
// client and browser see says nothing about the relay's network (FR-095).
func TestCIMDFailuresAreCachedAndSayNothing(t *testing.T) {
	e := setup(t)
	doc := newCIMDServer(t)
	doc.set(true, "")
	id := doc.URL + "/client.json"
	for range 3 {
		resp := e.authorizeStatus(id)
		assert.Equal(t, http.StatusUnauthorized, resp.StatusCode)
	}
	assert.Equal(t, 1, doc.fetched(), "one fetch, then the failure is remembered")
	e.clock.advance(6 * time.Minute)
	e.authorizeStatus(id)
	assert.Equal(t, 2, doc.fetched(), "for five minutes")

	// A host nothing listens on: the Go error names the address and the failure; none of it may
	// reach the caller.
	gone := httptest.NewTLSServer(http.NotFoundHandler())
	addr := strings.TrimPrefix(gone.URL, "https://")
	gone.Close()
	for _, target := range []string{gone.URL + "/client.json", doc.URL + "/client.json"} {
		resp := e.authorizeStatus(target)
		body, err := io.ReadAll(resp.Body)
		require.NoError(t, err)
		assert.Equal(t, http.StatusUnauthorized, resp.StatusCode)
		tokenResp, m := e.tokenRequest(url.Values{"grant_type": {"refresh_token"}, "refresh_token": {"x"}, "client_id": {target}})
		assert.Equal(t, http.StatusUnauthorized, tokenResp.StatusCode)
		for _, leak := range []string{addr, "127.0.0.1", "dial", "refused", "503", "connect"} {
			assert.NotContains(t, string(body), leak, target)
			assert.NotContains(t, fmt.Sprint(m), leak, target)
		}
	}
}

// What the client-lookup error itself carries is one fixed sentence (fosite hides hints of
// wrapped errors today; this holds even if that changes).
func TestCIMDErrorHintIsFixed(t *testing.T) {
	e := setup(t)
	gone := httptest.NewTLSServer(http.NotFoundHandler())
	gone.Close()
	hint := e.oauth.ClientLookupHint(ctxT(t), gone.URL+"/client.json")
	assert.Equal(t, "The client metadata document could not be fetched or is not valid.", hint)
}

package server

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/account"
	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/oauth"
	"github.com/tonimelisma/latchkey/relay/internal/store"
	"github.com/tonimelisma/latchkey/relay/internal/testagent"
)

// harness is the fully assembled relay on localhost, driven without a browser: Owners are
// created in the store with a session cookie (passkeys have their own tests), Claude's side is
// the OAuth flow by hand, and Macs are test agents.
type harness struct {
	t      *testing.T
	base   string
	dbPath string
	db     *store.Store
	relay  *Relay
	mail   *account.MemoryMailer
}

func newHarness(t *testing.T, tweak func(*Options)) *harness {
	t.Helper()
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "relay.db")
	db, err := store.Open(ctx, path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	srv := httptest.NewUnstartedServer(nil)
	_, port, _ := net.SplitHostPort(srv.Listener.Addr().String())
	h := &harness{t: t, base: "http://localhost:" + port, dbPath: path, db: db, mail: &account.MemoryMailer{}}
	public, _ := url.Parse(h.base)
	// Any client host: the tests register throwaway clients, which the default list refuses (FR-180).
	o := Options{
		PublicURL: public, Store: db, Mailer: h.mail, Logger: slog.New(slog.DiscardHandler),
		AllowedClients: oauth.AnyClientHost(),
	}
	o.Hub.HeartbeatInterval, o.Hub.OfflineAfter = time.Second, 5*time.Second
	if tweak != nil {
		tweak(&o)
	}
	h.relay, err = New(ctx, o)
	require.NoError(t, err)
	srv.Config.Handler = h.relay.Handler
	srv.Start()
	t.Cleanup(func() { h.relay.Hub.Close(); srv.Close() })
	return h
}

func tctx(t *testing.T) context.Context {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	t.Cleanup(cancel)
	return ctx
}

// owner is an account with a signed-in browser.
type owner struct {
	h    *harness
	user store.User
	http *http.Client
}

func (h *harness) owner(email string) *owner {
	h.t.Helper()
	ctx := context.Background()
	u, err := h.db.CreateUser(ctx, email, time.Now())
	require.NoError(h.t, err)
	require.NoError(h.t, h.db.VerifyEmail(ctx, u.ID, time.Now()))
	o := &owner{h: h, user: u}
	o.signIn()
	return o
}

// signIn gives the browser a fresh session, as a passkey sign-in would.
func (o *owner) signIn() {
	o.h.t.Helper()
	raw := make([]byte, 32)
	_, _ = rand.Read(raw)
	tok := base64.RawURLEncoding.EncodeToString(raw)
	sum := sha256.Sum256([]byte(tok))
	require.NoError(o.h.t, o.h.db.CreateSession(context.Background(), sum[:], o.user.ID, time.Now(), time.Now().Add(time.Hour)))
	jar, _ := cookiejar.New(nil)
	base, _ := url.Parse(o.h.base)
	// nosemgrep: go.lang.security.audit.net.cookie-missing-httponly.cookie-missing-httponly, go.lang.security.audit.net.cookie-missing-secure.cookie-missing-secure -- a request cookie in a test client
	jar.SetCookies(base, []*http.Cookie{{Name: "latchkey_session", Value: tok, Path: "/"}}) //nolint:gosec // a request cookie in a test client
	o.http = &http.Client{Jar: jar, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}

type reply struct {
	status int
	header http.Header
	body   string
}

func (h *harness) do(c *http.Client, method, path, contentType, body string, header map[string]string) reply {
	h.t.Helper()
	target := path
	if !strings.HasPrefix(path, "http") {
		target = h.base + path
	}
	req, err := http.NewRequestWithContext(tctx(h.t), method, target, strings.NewReader(body))
	require.NoError(h.t, err)
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	for k, v := range header {
		req.Header.Set(k, v)
	}
	if c == nil {
		c = &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	}
	resp, err := c.Do(req)
	require.NoError(h.t, err)
	defer func() { _ = resp.Body.Close() }()
	data, _ := io.ReadAll(resp.Body)
	return reply{resp.StatusCode, resp.Header, string(data)}
}

func (h *harness) get(path string) reply { return h.do(nil, http.MethodGet, path, "", "", nil) }

func (h *harness) postJSON(path string, v any) (int, map[string]any) {
	h.t.Helper()
	data, _ := json.Marshal(v)
	r := h.do(nil, http.MethodPost, path, "application/json", string(data), nil)
	var m map[string]any
	_ = json.Unmarshal([]byte(r.body), &m)
	return r.status, m
}

func (o *owner) get(path string) reply { return o.h.do(o.http, http.MethodGet, path, "", "", nil) }

func (o *owner) form(path string, v url.Values) reply {
	return o.h.do(o.http, http.MethodPost, path, "application/x-www-form-urlencoded", v.Encode(), nil)
}

var csrfRE = regexp.MustCompile(`name="csrf" value="([^"]+)"`)

func (o *owner) csrf(path string) string {
	o.h.t.Helper()
	m := csrfRE.FindStringSubmatch(o.get(path).body)
	require.NotNil(o.h.t, m, "no CSRF token on %s", path)
	return m[1]
}

const claudeCallback = "https://claude.ai/api/mcp/auth_callback"

// registerClient registers a client called "Claude" (dynamic registration) and returns its ID.
func (h *harness) registerClient(redirects ...string) string {
	h.t.Helper()
	status, m := h.postJSON("/register", map[string]any{
		"client_name": "Claude", "redirect_uris": redirects, "token_endpoint_auth_method": "none",
	})
	require.Equal(h.t, http.StatusCreated, status, m)
	id, _ := m["client_id"].(string)
	require.NotEmpty(h.t, id)
	return id
}

// approve is the whole of connecting an app: the Owner allows it on the consent page, and the
// client redeems its code.
func (o *owner) approve(clientID, redirect string) (access, refresh string) {
	o.h.t.Helper()
	verifier := strings.Repeat("v", 50)
	sum := sha256.Sum256([]byte(verifier))
	q := url.Values{
		"response_type": {"code"}, "client_id": {clientID}, "redirect_uri": {redirect},
		"scope": {"mcp offline_access"}, "state": {"state-123456789"},
		"code_challenge": {base64.RawURLEncoding.EncodeToString(sum[:])}, "code_challenge_method": {"S256"},
	}
	path := "/authorize?" + q.Encode()
	page := o.get(path)
	require.Equal(o.h.t, http.StatusOK, page.status, page.body)
	m := csrfRE.FindStringSubmatch(page.body)
	require.NotNil(o.h.t, m, "no consent form")
	r := o.form(path, url.Values{"csrf": {m[1]}, "decision": {"allow"}})
	loc, err := url.Parse(r.header.Get("Location"))
	require.NoError(o.h.t, err)
	code := loc.Query().Get("code")
	require.NotEmpty(o.h.t, code, "status %d, location %q", r.status, r.header.Get("Location"))
	tok := o.h.do(nil, http.MethodPost, "/token", "application/x-www-form-urlencoded", url.Values{
		"grant_type": {"authorization_code"}, "code": {code}, "redirect_uri": {redirect},
		"client_id": {clientID}, "code_verifier": {verifier},
	}.Encode(), nil)
	require.Equal(o.h.t, http.StatusOK, tok.status, tok.body)
	var out map[string]any
	require.NoError(o.h.t, json.Unmarshal([]byte(tok.body), &out))
	access, _ = out["access_token"].(string)
	refresh, _ = out["refresh_token"].(string)
	require.NotEmpty(o.h.t, access)
	return access, refresh
}

func mcpHeaders(access string) map[string]string {
	return map[string]string{"Authorization": "Bearer " + access, "Accept": "application/json, text/event-stream"}
}

// mcpStatus is the HTTP status of a ping to /mcp with the token.
func (h *harness) mcpStatus(access string) int {
	h.t.Helper()
	return h.do(nil, http.MethodPost, "/mcp", "application/json", `{"jsonrpc":"2.0","id":1,"method":"ping"}`, mcpHeaders(access)).status
}

// mcpSession opens a 2025-11-25 session with the token and returns its ID.
func (h *harness) mcpSession(access string) string {
	h.t.Helper()
	r := h.do(nil, http.MethodPost, "/mcp", "application/json",
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"claude","version":"1"}}}`,
		mcpHeaders(access))
	require.Equal(h.t, http.StatusOK, r.status, r.body)
	id := r.header.Get("Mcp-Session-Id")
	require.NotEmpty(h.t, id)
	return id
}

// mcpStream opens the session's event stream; the channel closes when the relay ends it.
func (h *harness) mcpStream(access, session string) <-chan struct{} {
	h.t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	h.t.Cleanup(cancel)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, h.base+"/mcp", nil)
	require.NoError(h.t, err)
	req.Header.Set("Authorization", "Bearer "+access)
	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set("Mcp-Session-Id", session)
	req.Header.Set("MCP-Protocol-Version", "2025-11-25")
	resp, err := http.DefaultClient.Do(req)
	require.NoError(h.t, err)
	require.Equal(h.t, http.StatusOK, resp.StatusCode)
	ended := make(chan struct{})
	go func() {
		defer close(ended)
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
	}()
	return ended
}

// mac pairs a test agent with the Owner's account; features is what its hello announces.
func (o *owner) mac(features ...string) *testagent.Agent {
	o.h.t.Helper()
	a := testagent.New("ws"+strings.TrimPrefix(o.h.base, "http")+"/agent/v1", "")
	a.Features = features
	d, err := o.h.db.CreateDevice(context.Background(),
		store.NewDevice{UserID: o.user.ID, Name: "Mac", PublicKey: a.PublicKeyDER()}, time.Now())
	require.NoError(o.h.t, err)
	a.DeviceID = d.ID
	return a
}

func (h *harness) dial(a *testagent.Agent) *testagent.Conn {
	h.t.Helper()
	c, err := a.Dial(tctx(h.t))
	require.NoError(h.t, err)
	h.t.Cleanup(func() { _ = c.Close() })
	require.Eventually(h.t, func() bool { return h.relay.Hub.Online(a.DeviceID) }, 5*time.Second, 10*time.Millisecond)
	return c
}

func nextClients(t *testing.T, c *testagent.Conn) []agentproto.Client {
	t.Helper()
	select {
	case m := <-c.Clients:
		return m.Clients
	case <-time.After(5 * time.Second):
		t.Fatal("the Mac got no clients message")
		return nil
	}
}

func noClients(t *testing.T, c *testagent.Conn) {
	t.Helper()
	select {
	case m := <-c.Clients:
		t.Fatalf("unexpected clients message: %+v", m)
	case <-time.After(300 * time.Millisecond):
	}
}

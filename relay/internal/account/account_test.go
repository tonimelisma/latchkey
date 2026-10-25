package account_test

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/account"
	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/oauth"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

type fakeMacs struct {
	mu      sync.Mutex
	online  map[string]bool
	revoked []string
	notices []*agentproto.Notice
}

func (f *fakeMacs) Online(id string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.online[id]
}

func (f *fakeMacs) Revoke(id string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.revoked = append(f.revoked, id)
}

func (f *fakeMacs) SendNotice(_ context.Context, _ string, n *agentproto.Notice) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.notices = append(f.notices, n)
	return nil
}

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *clock) advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

type env struct {
	t       *testing.T
	store   *store.Store
	mail    *account.MemoryMailer
	mailer  *gatedMailer // wraps mail
	svc     *account.Service
	macs    *fakeMacs
	clock   *clock
	base    string // http://localhost:<port>
	changed []string
	removed []string // user IDs whose Claude access was removed
}

func setup(t *testing.T, allowed ...string) *env {
	t.Helper()
	return setupWith(t, func(c *account.Config) { c.AllowedEmails = allowed })
}

// setupWith is setup with any other settings of the account service.
func setupWith(t *testing.T, tweak func(*account.Config)) *env {
	t.Helper()
	ctx := context.Background()
	st, err := store.Open(ctx, filepath.Join(t.TempDir(), "relay.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = st.Close() })
	e := &env{t: t, store: st, mail: &account.MemoryMailer{}, macs: &fakeMacs{online: map[string]bool{}}, clock: &clock{t: time.Now()}}
	e.mailer = &gatedMailer{MemoryMailer: e.mail}

	mux := http.NewServeMux()
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	_, port, _ := net.SplitHostPort(strings.TrimPrefix(srv.URL, "http://"))
	e.base = "http://localhost:" + port // WebAuthn needs a domain, not an IP
	public, _ := url.Parse(e.base)

	var svc *account.Service
	auth := &lateAuth{}
	o, err := oauth.New(ctx, oauth.Config{Issuer: public, Store: st, Auth: auth, Now: e.clock.now})
	require.NoError(t, err)
	cfg := account.Config{
		PublicURL: public, Store: st, Macs: e.macs, Mailer: e.mailer, OAuth: o,
		Now: e.clock.now, DevicesChanged: func(id string) { e.changed = append(e.changed, id) },
		AccessRemoved: func(id string) { e.removed = append(e.removed, id) },
	}
	tweak(&cfg)
	svc, err = account.New(ctx, cfg)
	require.NoError(t, err)
	auth.svc = svc
	e.svc = svc
	o.Register(mux)
	svc.Register(mux)
	return e
}

// lateAuth breaks the construction cycle between the OAuth server and the account service.
type lateAuth struct{ svc *account.Service }

func (l *lateAuth) CurrentUser(r *http.Request) (string, bool)    { return l.svc.CurrentUser(r) }
func (l *lateAuth) SignIn(w http.ResponseWriter, r *http.Request) { l.svc.SignIn(w, r) }
func (l *lateAuth) Consent(w http.ResponseWriter, r *http.Request, c oauth.ConsentRequest) {
	l.svc.Consent(w, r, c)
}
func (l *lateAuth) ValidCSRF(r *http.Request) bool { return l.svc.ValidCSRF(r) }

// browser is a cookie jar plus a passkey authenticator.
type browser struct {
	e     *env
	http  *http.Client
	authn *softAuthenticator
}

func (e *env) browser() *browser {
	jar, _ := cookiejar.New(nil)
	return &browser{e: e, authn: newSoftAuthenticator(), http: &http.Client{
		Jar: jar, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}
}

type resp struct {
	status int
	header http.Header
	body   string
}

func (b *browser) do(method, path, contentType string, body io.Reader) resp {
	b.e.t.Helper()
	target := path
	if !strings.HasPrefix(path, "http") {
		target = b.e.base + path
	}
	req, err := http.NewRequestWithContext(context.Background(), method, target, body)
	require.NoError(b.e.t, err)
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	r, err := b.http.Do(req)
	require.NoError(b.e.t, err)
	defer func() { _ = r.Body.Close() }()
	data, _ := io.ReadAll(r.Body)
	return resp{r.StatusCode, r.Header, string(data)}
}

func (b *browser) get(path string) resp { return b.do(http.MethodGet, path, "", nil) }

func (b *browser) form(path string, v url.Values) resp {
	return b.do(http.MethodPost, path, "application/x-www-form-urlencoded", strings.NewReader(v.Encode()))
}

func (b *browser) json(path string, v any) (int, map[string]any) {
	b.e.t.Helper()
	data, _ := json.Marshal(v)
	r := b.do(http.MethodPost, path, "application/json", strings.NewReader(string(data)))
	var m map[string]any
	_ = json.Unmarshal([]byte(r.body), &m)
	return r.status, m
}

var (
	codeRE = regexp.MustCompile(`\b(\d{6})\b`)
	csrfRE = regexp.MustCompile(`name="csrf" value="([^"]+)"`)
)

func csrf(t *testing.T, body string) string {
	t.Helper()
	m := csrfRE.FindStringSubmatch(body)
	require.NotNil(t, m, "no CSRF token on page")
	return m[1]
}

func (b *browser) signIn(purpose string, c *softCred) (int, map[string]any) {
	b.e.t.Helper()
	status, begin := b.json("/passkey/login/begin", map[string]string{"purpose": purpose})
	require.Equal(b.e.t, http.StatusOK, status, begin)
	if c == nil {
		c = b.authn.only(b.e.t)
	}
	assertion := b.authn.get(b.e.t, begin["options"].(map[string]any), b.e.base, c)
	return b.json("/passkey/login/finish?ceremony="+begin["ceremony"].(string)+"&next=/account", assertion)
}

func TestUnknownPasskeyRejected(t *testing.T) {
	e := setup(t)
	e.browser().signUp()
	stranger := e.browser()
	stranger.authn.creds["x"] = &softCred{id: []byte("unknown-credential"), key: mustKey(t), userHandle: []byte("usr_x"), rpID: "localhost"}
	status, _ := stranger.signIn("signin", stranger.authn.creds["x"])
	assert.Equal(t, http.StatusUnauthorized, status)
}

func mustKey(t *testing.T) *ecdsa.PrivateKey {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	return k
}

// service builds a second service over the same store, for calling Go methods directly.
func (e *env) service(t *testing.T) *account.Service {
	public, _ := url.Parse(e.base)
	o, err := oauth.New(context.Background(), oauth.Config{Issuer: public, Store: e.store, Auth: &lateAuth{}})
	require.NoError(t, err)
	svc, err := account.New(context.Background(), account.Config{PublicURL: public, Store: e.store, Macs: e.macs, Mailer: e.mail, OAuth: o, Now: e.clock.now})
	require.NoError(t, err)
	return svc
}

func TestDeleteAccountNeedsFreshPasskey(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.signUp()
	u, _ := e.store.UserByEmail(context.Background(), "owner@example.com")
	d, err := e.store.CreateDevice(context.Background(), store.NewDevice{UserID: u.ID, Name: "Mac", PublicKey: []byte("k")}, e.clock.now())
	require.NoError(t, err)

	token := csrf(t, b.get("/account").body)
	r := b.form("/account/delete", url.Values{"csrf": {token}})
	assert.Equal(t, http.StatusForbidden, r.status, "no fresh passkey check yet")

	status, _ := b.signIn("reauth", nil)
	require.Equal(t, http.StatusOK, status)
	r = b.form("/account/delete", url.Values{"csrf": {"wrong"}})
	assert.Equal(t, http.StatusForbidden, r.status, "CSRF")
	r = b.form("/account/delete", url.Values{"csrf": {token}})
	require.Equal(t, http.StatusOK, r.status, r.body)
	assert.Contains(t, r.body, "Your account was deleted")

	_, err = e.store.User(context.Background(), u.ID)
	require.ErrorIs(t, err, store.ErrNotFound, "FR-045")
	assert.Contains(t, e.macs.revoked, d.ID, "the Mac is disconnected")
	assert.Equal(t, http.StatusFound, b.get("/account").status, "signed out")
	assert.Equal(t, []string{u.ID}, e.removed, "nothing of the account stays in memory")
}

func TestReauthExpires(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.signUp()
	token := csrf(t, b.get("/account").body)
	b.signIn("reauth", nil)
	e.clock.advance(6 * time.Minute)
	assert.Equal(t, http.StatusForbidden, b.form("/account/delete", url.Values{"csrf": {token}}).status)
}

func TestSessionLasts30Days(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.signUp()
	e.clock.advance(29 * 24 * time.Hour)
	assert.Equal(t, http.StatusOK, b.get("/account").status)
	e.clock.advance(2 * 24 * time.Hour)
	assert.Equal(t, http.StatusFound, b.get("/account").status, "FR-048")
}

func p256DER(t *testing.T) string {
	der, err := x509.MarshalPKIXPublicKey(&mustKey(t).PublicKey)
	require.NoError(t, err)
	return b64.EncodeToString(der)
}

func (b *browser) pairCode(name string) string {
	b.e.t.Helper()
	page := b.get("/pair?name=" + url.QueryEscape(name))
	require.Equal(b.e.t, http.StatusOK, page.status)
	r := b.form("/pair", url.Values{"csrf": {csrf(b.e.t, page.body)}})
	require.Equal(b.e.t, http.StatusSeeOther, r.status)
	loc, err := url.Parse(r.header.Get("Location"))
	require.NoError(b.e.t, err)
	require.Equal(b.e.t, "latchkey", loc.Scheme)
	require.Equal(b.e.t, "paired", loc.Host)
	require.Equal(b.e.t, b.e.base, loc.Query().Get("relay"), "the link names the relay")
	return loc.Query().Get("code")
}

func TestPairing(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.signUp()
	u, _ := e.store.UserByEmail(context.Background(), "owner@example.com")

	page := b.get("/pair?name=Toni%27s+MacBook")
	assert.Contains(t, page.body, "Toni&#39;s MacBook")
	assert.NotContains(t, page.body, "disconnects")

	code := b.pairCode("Toni's MacBook")
	mac := e.browser() // the app calls exchange without cookies
	status, m := mac.json("/pair/exchange", map[string]string{"code": code, "public_key": p256DER(t), "name": "Toni's MacBook"})
	require.Equal(t, http.StatusOK, status, m)
	first, err := e.store.ActiveDevice(context.Background(), u.ID)
	require.NoError(t, err)
	assert.Equal(t, m["device_id"], first.ID)
	assert.Equal(t, "Toni's MacBook", first.Name)
	assert.Contains(t, e.changed, u.ID)

	status, _ = mac.json("/pair/exchange", map[string]string{"code": code, "public_key": p256DER(t)})
	assert.Equal(t, http.StatusBadRequest, status, "codes are single-use")

	// A second Mac: the page names the one it replaces (FR-053).
	page = b.get("/pair?name=New+MacBook")
	assert.Contains(t, page.body, "disconnects “Toni&#39;s MacBook”")
	code = b.pairCode("New MacBook")
	status, _ = mac.json("/pair/exchange", map[string]string{"code": code, "public_key": p256DER(t), "name": "New MacBook"})
	require.Equal(t, http.StatusOK, status)
	assert.Contains(t, e.macs.revoked, first.ID)
	now, err := e.store.ActiveDevice(context.Background(), u.ID)
	require.NoError(t, err)
	assert.Equal(t, "New MacBook", now.Name)
}

func TestPairingRules(t *testing.T) {
	e := setup(t)
	b := e.browser()
	assert.Equal(t, http.StatusFound, b.get("/pair").status, "sign in first")
	b.signUp()

	code := b.pairCode("Mac")
	status, _ := b.json("/pair/exchange", map[string]string{"code": code, "public_key": "not-a-key"})
	assert.Equal(t, http.StatusBadRequest, status)

	e.clock.advance(6 * time.Minute)
	status, _ = b.json("/pair/exchange", map[string]string{"code": code, "public_key": p256DER(t)})
	assert.Equal(t, http.StatusBadRequest, status, "codes expire after 5 minutes")

	r := b.form("/pair", url.Values{"csrf": {"forged"}})
	assert.Equal(t, http.StatusForbidden, r.status)
}

// The app looks up whose code a pairing link carries before it asks the Owner (FR-054).
func TestPairingPreview(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.signUp()
	code := b.pairCode("Mac")
	mac := e.browser() // the app calls preview without cookies

	status, m := mac.json("/pair/preview", map[string]string{"code": code})
	require.Equal(t, http.StatusOK, status, m)
	assert.Equal(t, "owner@example.com", m["email"], "names the account the code belongs to")

	r := mac.do(http.MethodPost, "/pair/preview", "text/plain", strings.NewReader(`{"code":"`+code+`"}`))
	assert.Equal(t, http.StatusUnsupportedMediaType, r.status, "JSON only")

	status, m = mac.json("/pair/preview", map[string]string{"code": "unknown"})
	assert.Equal(t, http.StatusBadRequest, status)
	assert.Contains(t, m["error"], "expired")

	// Looking up doesn't use the code: the exchange still works, and after it the lookup fails.
	status, m = mac.json("/pair/exchange", map[string]string{"code": code, "public_key": p256DER(t), "name": "Mac"})
	require.Equal(t, http.StatusOK, status, m)
	status, _ = mac.json("/pair/preview", map[string]string{"code": code})
	assert.Equal(t, http.StatusBadRequest, status, "a used code names no one")

	code = b.pairCode("Mac")
	e.clock.advance(6 * time.Minute)
	status, m = mac.json("/pair/preview", map[string]string{"code": code})
	assert.Equal(t, http.StatusBadRequest, status, "an expired code names no one")
	assert.Contains(t, m["error"], "expired")
}

func TestRevokeMacAndClaude(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.signUp()
	u, _ := e.store.UserByEmail(context.Background(), "owner@example.com")
	d, err := e.store.CreateDevice(context.Background(), store.NewDevice{UserID: u.ID, Name: "Mac", PublicKey: []byte("k")}, e.clock.now())
	require.NoError(t, err)
	require.NoError(t, e.store.PutOAuthRequest(context.Background(), store.OAuthRequest{
		Signature: "sig-refresh", Kind: store.KindRefresh, RequestID: "req1", ClientID: "cl_x", UserID: u.ID,
		RequestedAt: e.clock.now(), SessionJSON: []byte(`{}`), ExpiresAt: e.clock.now().Add(time.Hour),
	}))
	require.NoError(t, e.store.AddGrant(context.Background(), store.Grant{
		RequestID: "req1", ID: store.NewGrantID(), UserID: u.ID, ClientID: "cl_x",
		ClientName: "Claude", ClientHost: "claude.ai", Redirect: "claude.ai", ApprovedAt: e.clock.now(),
	}))

	page := b.get("/account")
	assert.Contains(t, page.body, "Disconnect Mac")
	assert.Contains(t, page.body, "Remove Claude")
	token := csrf(t, page.body)

	r := b.form("/account/revoke-mac", url.Values{"csrf": {token}})
	assert.Equal(t, http.StatusSeeOther, r.status)
	assert.Contains(t, e.macs.revoked, d.ID)
	_, err = e.store.ActiveDevice(context.Background(), u.ID)
	require.ErrorIs(t, err, store.ErrNotFound)

	r = b.form("/account/revoke-claude", url.Values{"csrf": {token}})
	assert.Equal(t, http.StatusSeeOther, r.status)
	_, err = e.store.OAuthRequest(context.Background(), store.KindRefresh, "sig-refresh")
	require.ErrorIs(t, err, store.ErrNotFound)
	assert.NotContains(t, b.get("/account").body, "Remove Claude", "no client is listed any more")
	assert.Equal(t, []string{u.ID}, e.removed, "Claude's sessions in memory are dropped too")
}

func TestPasskeyEndpointsNeedJSON(t *testing.T) {
	e := setup(t)
	r := e.browser().form("/passkey/login/begin", url.Values{"purpose": {"signin"}})
	assert.Equal(t, http.StatusUnsupportedMediaType, r.status)
}

// A cross-site page can post text/plain without a CORS preflight. It must not be able to finish
// a passkey ceremony the attacker started, which would sign the victim's browser in to the
// attacker's account (login CSRF, security scan).
func TestPasskeyFinishRefusesCrossSiteForms(t *testing.T) {
	e := setup(t)
	attacker := e.browser()
	attacker.signUp()
	status, begin := attacker.json("/passkey/login/begin", map[string]string{"purpose": "signin"})
	require.Equal(t, http.StatusOK, status)
	assertion := attacker.authn.get(t, begin["options"].(map[string]any), e.base, attacker.authn.only(t))
	body, _ := json.Marshal(assertion)

	victim := e.browser()
	r := victim.do(http.MethodPost, "/passkey/login/finish?ceremony="+begin["ceremony"].(string)+"&next=/account",
		"text/plain", strings.NewReader(string(body)))
	assert.Equal(t, http.StatusUnsupportedMediaType, r.status, r.body)
	assert.Empty(t, r.header.Values("Set-Cookie"), "no session for the victim's browser")
	assert.Equal(t, http.StatusFound, victim.get("/account").status, "the victim is not signed in")

	r = victim.do(http.MethodPost, "/passkey/register/finish?ceremony=x", "text/plain", strings.NewReader("{}"))
	assert.Equal(t, http.StatusUnsupportedMediaType, r.status, r.body)
}

func TestConsentPageViaAuthorize(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.signUp()
	status, reg := b.json("/register", map[string]any{"client_name": "Claude", "redirect_uris": []string{"https://claude.ai/api/mcp/auth_callback"}, "token_endpoint_auth_method": "none"})
	require.Equal(t, http.StatusCreated, status)
	q := url.Values{
		"response_type": {"code"}, "client_id": {reg["client_id"].(string)}, "redirect_uri": {"https://claude.ai/api/mcp/auth_callback"},
		"scope": {"mcp offline_access"}, "state": {"abcdefghijk"}, "code_challenge": {"E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"}, "code_challenge_method": {"S256"},
	}
	page := b.get("/authorize?" + q.Encode())
	require.Equal(t, http.StatusOK, page.status)
	assert.Contains(t, page.body, "<h1>Allow Claude to use your Mac?</h1>", "the name the client gave")
	assert.Contains(t, page.body, `<p class="host">This app is at <strong>claude.ai</strong>.`, "the host the relay checked, on its own")
	assert.Contains(t, page.body, "claude.ai")
	r := b.form("/authorize?"+q.Encode(), url.Values{"csrf": {csrf(t, page.body)}, "decision": {"allow"}})
	require.Contains(t, []int{http.StatusFound, http.StatusSeeOther}, r.status, r.body)
	assert.True(t, strings.HasPrefix(r.header.Get("Location"), "https://claude.ai/api/mcp/auth_callback?code="))
	assert.NotContains(t, b.get("/account").body, "Remove Claude", "approved, but no token yet: nothing has access")

	// The client redeems its code (the RFC 7636 example verifier); from then on it has access.
	loc, err := url.Parse(r.header.Get("Location"))
	require.NoError(t, err)
	tok := b.form("/token", url.Values{
		"grant_type": {"authorization_code"}, "code": {loc.Query().Get("code")}, "client_id": {reg["client_id"].(string)},
		"redirect_uri": {"https://claude.ai/api/mcp/auth_callback"}, "code_verifier": {"dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"},
	})
	require.Equal(t, http.StatusOK, tok.status, tok.body)
	assert.Contains(t, b.get("/account").body, "<strong>Claude (claude.ai)</strong>", "the account page names it the same way")

	// Asked again the next time, although this client was approved (FR-049a).
	again := b.get("/authorize?" + q.Encode())
	assert.Equal(t, http.StatusOK, again.status)
	assert.Contains(t, again.body, "<h1>Allow Claude to use your Mac?</h1>")
}

const owner = "owner@example.com"

// lastCode is the code in the newest email to the owner.
func (e *env) lastCode() string {
	e.t.Helper()
	msgs := e.mail.Sent()
	for i := len(msgs) - 1; i >= 0; i-- {
		if msgs[i].To == owner {
			return codeRE.FindStringSubmatch(msgs[i].Body)[1]
		}
	}
	e.t.Fatal("no email to the owner")
	return ""
}

// startEmail is the first step of the sign-in page. A recovery code is emailed in the
// background; this waits for it, so the test can read it.
func (b *browser) startEmail(email string, recover bool) (int, map[string]any) {
	status, r := b.json("/auth/email", map[string]any{"email": email, "recover": recover})
	b.e.svc.WaitForMail()
	return status, r
}

// confirmCode enters a code and returns the ticket for creating a passkey.
func (b *browser) confirmCode(code, purpose string) (int, map[string]any) {
	return b.json("/auth/code", map[string]string{"email": owner, "code": code, "purpose": purpose})
}

// createPasskey runs the last step with a ticket.
func (b *browser) createPasskey(ticket string) (int, map[string]any) {
	b.e.t.Helper()
	status, begin := b.json("/passkey/register/begin", map[string]string{"ticket": ticket})
	require.Equal(b.e.t, http.StatusOK, status, begin)
	cred := b.authn.create(b.e.t, begin["options"].(map[string]any), b.e.base)
	return b.json("/passkey/register/finish?ceremony="+begin["ceremony"].(string)+"&next=/account", cred)
}

// codeFlow runs email → code → passkey for a purpose.
func (b *browser) codeFlow(purpose string) {
	b.e.t.Helper()
	status, r := b.startEmail(owner, purpose == store.PurposeRecover)
	require.Equal(b.e.t, http.StatusOK, status, r)
	require.Equal(b.e.t, "code", r["step"])
	require.Equal(b.e.t, purpose, r["purpose"])
	status, t := b.confirmCode(b.e.lastCode(), purpose)
	require.Equal(b.e.t, http.StatusOK, status, t)
	status, done := b.createPasskey(t["ticket"].(string))
	require.Equal(b.e.t, http.StatusOK, status, done)
	assert.Equal(b.e.t, "/account", done["next"])
}

func (b *browser) signUp() { b.codeFlow(store.PurposeVerify) }

func TestSignUpWithEmailCode(t *testing.T) {
	e := setup(t)
	b := e.browser()
	status, r := b.startEmail(" Owner@Example.com ", false)
	require.Equal(t, http.StatusOK, status)
	assert.Equal(t, map[string]any{"step": "code", "purpose": "verify"}, r)
	require.Len(t, e.mail.Sent(), 1)
	code := e.lastCode()
	assert.Equal(t, "Your Latchkey code: "+code, e.mail.Sent()[0].Subject)

	status, ticket := b.confirmCode(code, store.PurposeVerify)
	require.Equal(t, http.StatusOK, status, ticket)
	status, done := b.createPasskey(ticket["ticket"].(string))
	require.Equal(t, http.StatusOK, status, done)

	u, err := e.store.UserByEmail(context.Background(), owner)
	require.NoError(t, err)
	assert.False(t, u.EmailVerifiedAt.IsZero(), "FR-043")
	keys, err := e.store.Passkeys(context.Background(), u.ID)
	require.NoError(t, err)
	assert.Len(t, keys, 1)
	assert.Equal(t, http.StatusOK, b.get("/account").status)

	status, _ = b.confirmCode(code, store.PurposeVerify)
	assert.Equal(t, http.StatusBadRequest, status, "codes are single-use")
}

func TestWrongCodesLock(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.startEmail(owner, false)
	code := e.lastCode()
	wrong := "000000"
	if code == wrong {
		wrong = "111111"
	}
	for range store.MaxCodeAttempts {
		status, r := b.confirmCode(wrong, store.PurposeVerify)
		require.Equal(t, http.StatusBadRequest, status)
		assert.Contains(t, r["error"], "isn't right")
	}
	status, r := b.confirmCode(code, store.PurposeVerify)
	assert.Equal(t, http.StatusBadRequest, status, "locked after 5 wrong codes")
	assert.Contains(t, r["error"], "get a new code")
}

// FR-042a: 20 wrong codes within a day stop every emailed code for that address until the day
// is over, whatever new codes are sent; the passkey still signs in.
func TestTwentyWrongCodesStopCodesForADay(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.signUp()
	attacker := e.browser()
	for range store.MaxWrongCodesPerDay / store.MaxCodeAttempts {
		e.clock.advance(11 * time.Minute) // past the per-address email limit
		status, _ := attacker.startEmail(owner, true)
		require.Equal(t, http.StatusOK, status)
		wrong := "000000"
		if e.lastCode() == wrong {
			wrong = "111111"
		}
		for range store.MaxCodeAttempts {
			status, r := attacker.confirmCode(wrong, store.PurposeRecover)
			require.Equal(t, http.StatusBadRequest, status)
			require.Contains(t, r["error"], "isn't right")
		}
	}
	sent := len(e.mail.Sent())
	e.clock.advance(11 * time.Minute)
	status, r := e.browser().startEmail(owner, true)
	require.Equal(t, http.StatusOK, status, "the answer looks the same")
	assert.Equal(t, "code", r["step"])
	assert.Len(t, e.mail.Sent(), sent, "no code is sent while codes are refused")

	status, r = e.browser().confirmCode(e.lastCode(), store.PurposeRecover)
	assert.Equal(t, http.StatusTooManyRequests, status)
	assert.Contains(t, r["error"], "passkey")
	assert.Contains(t, r["error"], "tomorrow")

	status, done := b.signIn("signin", nil)
	assert.Equal(t, http.StatusOK, status, done)

	e.clock.advance(24 * time.Hour)
	lost := e.browser()
	lost.codeFlow(store.PurposeRecover) // a day later, codes work again
}

func TestCodeExpires(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.startEmail(owner, false)
	e.clock.advance(16 * time.Minute)
	status, _ := b.confirmCode(e.lastCode(), store.PurposeVerify)
	assert.Equal(t, http.StatusBadRequest, status)
}

func TestTicketCannotBeGuessed(t *testing.T) {
	e := setup(t)
	status, _ := e.browser().json("/passkey/register/begin", map[string]string{"ticket": "made-up"})
	assert.Equal(t, http.StatusBadRequest, status)
}

func TestNoPasswordAnywhere(t *testing.T) {
	e := setup(t)
	b := e.browser()
	for _, p := range []string{"/", "/signin", "/signin?recover=1"} {
		page := b.get(p)
		require.Equal(t, http.StatusOK, page.status, p)
		assert.NotContains(t, strings.ToLower(page.body), `type="password"`, p)
	}
}

func TestOldAddressesLeadToSignIn(t *testing.T) {
	e := setup(t)
	r := e.browser().get("/signup?next=/pair")
	assert.Equal(t, http.StatusFound, r.status)
	assert.Equal(t, "/signin?next=%2Fpair", r.header.Get("Location"))
	r = e.browser().get("/recover")
	assert.Contains(t, r.header.Get("Location"), "recover=1")
}

func TestKnownAccountGoesToPasskey(t *testing.T) {
	e := setup(t)
	first := e.browser()
	first.signUp()
	sent := len(e.mail.Sent())

	other := e.browser()
	other.authn = first.authn // the same passkey, synced to another browser
	status, r := other.startEmail(owner, false)
	require.Equal(t, http.StatusOK, status)
	assert.Equal(t, "passkey", r["step"])
	assert.Len(t, e.mail.Sent(), sent, "no email for a known account")

	status, done := other.signIn("signin", nil)
	require.Equal(t, http.StatusOK, status, done)
	assert.Equal(t, http.StatusOK, other.get("/account").status)
}

func TestEmailRateLimit(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.startEmail(owner, false)
	first := e.lastCode()
	status, r := b.startEmail(owner, false)
	assert.Equal(t, http.StatusOK, status)
	assert.Equal(t, "code", r["step"])
	assert.Len(t, e.mail.Sent(), 1, "at most one email per minute per address")
	status, _ = b.confirmCode(first, store.PurposeVerify)
	assert.Equal(t, http.StatusOK, status, "the earlier code still works")

	e.clock.advance(61 * time.Second)
	b.startEmail(owner, false)
	assert.Len(t, e.mail.Sent(), 2)
}

func TestEmailHourlyCap(t *testing.T) {
	e := setup(t)
	b := e.browser()
	for range 20 {
		b.startEmail(owner, false)
		e.clock.advance(61 * time.Second)
	}
	// Five at once (minutes 0–4), then one when the next token refills ten minutes in.
	assert.Len(t, e.mail.Sent(), 6, "at most six codes in 20 minutes")
	e.clock.advance(time.Hour)
	b.startEmail(owner, false)
	assert.Len(t, e.mail.Sent(), 7, "an hour later, codes flow again")
}

func TestAllowedEmails(t *testing.T) {
	e := setup(t, "Toni@example.com")
	status, r := e.browser().startEmail("stranger@example.com", false)
	assert.Equal(t, http.StatusForbidden, status)
	assert.Contains(t, r["error"], "approved email")
	assert.Empty(t, e.mail.Sent())
	status, _ = e.browser().startEmail("toni@example.com", false)
	assert.Equal(t, http.StatusOK, status)
	assert.Len(t, e.mail.Sent(), 1)
}

func TestInvalidEmail(t *testing.T) {
	e := setup(t)
	status, r := e.browser().startEmail("not an email", false)
	assert.Equal(t, http.StatusBadRequest, status)
	assert.Contains(t, r["error"], "valid email")
}

func TestRecovery(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.signUp()
	oldCred := b.authn.only(t)
	u, err := e.store.UserByEmail(context.Background(), owner)
	require.NoError(t, err)
	d, err := e.store.CreateDevice(context.Background(), store.NewDevice{UserID: u.ID, Name: "Mac", PublicKey: []byte("k")}, e.clock.now())
	require.NoError(t, err)
	e.macs.online[d.ID] = true
	// A Claude client approved before the recovery (perhaps by whoever took the passkeys).
	ctx := context.Background()
	for _, kind := range []string{store.KindCode, store.KindRefresh} {
		require.NoError(t, e.store.PutOAuthRequest(ctx, store.OAuthRequest{
			Signature: "sig-" + kind, Kind: kind, RequestID: "req1", ClientID: "cl_x", UserID: u.ID,
			RequestedAt: e.clock.now(), SessionJSON: []byte(`{}`), ExpiresAt: e.clock.now().Add(time.Hour),
		}))
	}

	lost := e.browser() // the passkeys are gone; a new device
	e.clock.advance(2 * time.Minute)
	lost.codeFlow(store.PurposeRecover)
	assert.Contains(t, e.mail.Sent()[len(e.mail.Sent())-2].Subject, "recovery code")
	assert.Equal(t, http.StatusOK, lost.get("/account").status, "signed in with the new passkey")

	keys, err := e.store.Passkeys(context.Background(), u.ID)
	require.NoError(t, err)
	assert.Len(t, keys, 1, "old passkeys removed (FR-047)")
	assert.Equal(t, http.StatusFound, b.get("/account").status, "old sessions signed out")
	status, _ := b.signIn("signin", oldCred)
	assert.Equal(t, http.StatusUnauthorized, status, "the old passkey no longer works")
	_, err = e.store.OAuthRequest(ctx, store.KindRefresh, "sig-refresh")
	require.ErrorIs(t, err, store.ErrNotFound, "Claude's tokens are removed (FR-047a)")
	assert.Equal(t, []string{u.ID}, e.removed, "and Claude's sessions in memory")

	msgs := e.mail.Sent()
	assert.Equal(t, "Your Latchkey account was recovered", msgs[len(msgs)-1].Subject, "announced by email")
	require.Len(t, e.macs.notices, 1, "announced on the Mac")
	assert.Equal(t, agentproto.NoticeAccountRecovered, e.macs.notices[0].Kind)
}

func TestRecoveryForUnknownEmailLooksTheSame(t *testing.T) {
	e := setup(t)
	status, r := e.browser().startEmail("nobody@example.com", true)
	assert.Equal(t, http.StatusOK, status)
	assert.Equal(t, "code", r["step"])
	assert.Empty(t, e.mail.Sent())
}

func TestNoticesOnConnect(t *testing.T) {
	e := setup(t)
	e.browser().signUp()
	u, _ := e.store.UserByEmail(context.Background(), owner)
	d, err := e.store.CreateDevice(context.Background(), store.NewDevice{UserID: u.ID, Name: "Mac", PublicKey: []byte("k")}, e.clock.now())
	require.NoError(t, err)
	connected := e.clock.now()

	e.clock.advance(2 * time.Minute)
	e.browser().codeFlow(store.PurposeRecover)
	assert.Empty(t, e.macs.notices, "the Mac was offline")

	svc := e.service(t)
	notices := svc.NoticesOnConnect(context.Background(), d, connected)
	require.Len(t, notices, 1, "told on its next connection")
	assert.Empty(t, svc.NoticesOnConnect(context.Background(), d, e.clock.now()), "only once")
}

func TestNewClientAccessIsAnnouncedOnce(t *testing.T) {
	e := setup(t)
	e.browser().signUp()
	ctx := context.Background()
	u, _ := e.store.UserByEmail(ctx, owner)
	d, err := e.store.CreateDevice(ctx, store.NewDevice{UserID: u.ID, Name: "Mac", PublicKey: []byte("k")}, e.clock.now())
	require.NoError(t, err)
	svc := e.service(t)

	// Offline: kept for the next connection, told once.
	e.clock.advance(time.Minute)
	svc.ClientAuthorized(ctx, u.ID, "Claude")
	assert.Empty(t, e.macs.notices)
	notices := svc.NoticesOnConnect(ctx, d, time.Time{})
	require.Len(t, notices, 1)
	assert.Equal(t, agentproto.NoticeClientAuthorized, notices[0].Kind)
	assert.Equal(t, "Claude", notices[0].Client)
	assert.Empty(t, svc.NoticesOnConnect(ctx, d, time.Time{}), "only once")

	// Online: told right away, and not again on the next connection.
	e.macs.mu.Lock()
	e.macs.online[d.ID] = true
	e.macs.mu.Unlock()
	svc.ClientAuthorized(ctx, u.ID, "Claude Code")
	require.Len(t, e.macs.notices, 1)
	assert.Equal(t, "Claude Code", e.macs.notices[0].Client)
	assert.Empty(t, svc.NoticesOnConnect(ctx, d, time.Time{}))
}

func TestNextIsAlwaysLocal(t *testing.T) {
	e := setup(t)
	page := e.browser().get("/signin?next=//evil.example/x")
	assert.Contains(t, page.body, `data-next="/account"`)
	page = e.browser().get("/signin?next=" + url.QueryEscape("/authorize?client_id=x"))
	assert.Contains(t, page.body, `data-next="/authorize?client_id=x"`)

	// Browsers drop tab and newline from URLs and read a backslash as a slash, so each of these
	// would leave the site after sign-in (security scan).
	for _, next := range []string{
		"/\t/evil.example", "/\n\\evil.example", "/\r//evil.example", "\\evil.example", "/\\evil.example",
		"/x\\..\\..\\/evil.example", "https://evil.example/", "/\x7f/evil.example", "/\x00/evil.example",
	} {
		page = e.browser().get("/signin?next=" + url.QueryEscape(next))
		assert.Contains(t, page.body, `data-next="/account"`, "%q", next)
	}
	// What a passkey sign-in sends back is checked the same way.
	b := e.browser()
	b.signUp()
	status, begin := b.json("/passkey/login/begin", map[string]string{"purpose": "signin"})
	require.Equal(t, http.StatusOK, status)
	assertion := b.authn.get(t, begin["options"].(map[string]any), e.base, b.authn.only(t))
	status, done := b.json("/passkey/login/finish?"+url.Values{
		"ceremony": {begin["ceremony"].(string)}, "next": {"/\t/evil.example"},
	}.Encode(), assertion)
	require.Equal(t, http.StatusOK, status, done)
	assert.Equal(t, "/account", done["next"])
}

// gatedMailer is the tests' mailer: it records like MemoryMailer, and can be made to hang like
// a slow mail server.
type gatedMailer struct {
	*account.MemoryMailer
	mu   sync.Mutex
	gate chan struct{} // non-nil: Send waits until it is closed
}

func (g *gatedMailer) Send(ctx context.Context, to, subject, body string) error {
	g.mu.Lock()
	gate := g.gate
	g.mu.Unlock()
	if gate != nil {
		select {
		case <-gate:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return g.MemoryMailer.Send(ctx, to, subject, body)
}

func (g *gatedMailer) hold() (release func()) {
	gate := make(chan struct{})
	g.mu.Lock()
	g.gate = gate
	g.mu.Unlock()
	return sync.OnceFunc(func() {
		g.mu.Lock()
		g.gate = nil
		g.mu.Unlock()
		close(gate)
	})
}

// A recovery request answers at once, the same for an address with an account and one without:
// the email is sent in the background, so how long the mail server takes tells a stranger
// nothing about who has an account (FR-042b).
func TestRecoveryAnswersBeforeTheMailIsSent(t *testing.T) {
	e := setup(t)
	e.browser().signUp()
	e.clock.advance(2 * time.Minute)
	release := e.mailer.hold() // the mail server is slow
	defer release()
	before := len(e.mail.Sent())

	answered := make(chan map[string]any, 2)
	for _, addr := range []string{owner, "nobody@example.com"} {
		go func() {
			data, _ := json.Marshal(map[string]any{"email": addr, "recover": true})
			req, _ := http.NewRequestWithContext(context.Background(), http.MethodPost, e.base+"/auth/email", strings.NewReader(string(data)))
			req.Header.Set("Content-Type", "application/json")
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				return
			}
			defer func() { _ = resp.Body.Close() }()
			var m map[string]any
			_ = json.NewDecoder(resp.Body).Decode(&m)
			answered <- m
		}()
	}
	for range 2 {
		select {
		case m := <-answered:
			assert.Equal(t, map[string]any{"step": "code", "purpose": "recover"}, m, "the same answer for both")
		case <-time.After(2 * time.Second):
			t.Fatal("the answer waited for the mail server, which only happens for a real account")
		}
	}
	assert.Len(t, e.mail.Sent(), before, "nothing sent yet")
	release()
	e.svc.WaitForMail()
	msgs := e.mail.Sent()
	require.Len(t, msgs, before+1, "the account's code goes out in the background")
	assert.Contains(t, msgs[len(msgs)-1].Subject, "recovery code")
	assert.Equal(t, owner, msgs[len(msgs)-1].To)
}

// One ticket makes one passkey, even when two registrations started from it finish at the same
// moment.
func TestTicketIsTakenOnce(t *testing.T) {
	e := setup(t)
	for range 5 {
		b := e.browser()
		e.clock.advance(11 * time.Minute)
		status, r := b.startEmail(owner, false)
		require.Equal(t, http.StatusOK, status, r)
		if r["step"] != "code" { // signed up in an earlier round: recover instead
			status, r = b.startEmail(owner, true)
			require.Equal(t, http.StatusOK, status, r)
		}
		purpose := r["purpose"].(string)
		status, tk := b.confirmCode(e.lastCode(), purpose)
		require.Equal(t, http.StatusOK, status, tk)
		ticket := tk["ticket"].(string)

		type started struct {
			ceremony string
			cred     any
		}
		var both []started
		for range 2 {
			status, begin := b.json("/passkey/register/begin", map[string]string{"ticket": ticket})
			require.Equal(t, http.StatusOK, status, begin)
			both = append(both, started{begin["ceremony"].(string), b.authn.create(t, begin["options"].(map[string]any), e.base)})
		}
		u, err := e.store.UserByEmail(context.Background(), owner)
		require.NoError(t, err)
		before, err := e.store.Passkeys(context.Background(), u.ID)
		require.NoError(t, err)

		statuses := make(chan int, 2)
		for _, s := range both {
			go func() {
				status, _ := e.browser().json("/passkey/register/finish?ceremony="+s.ceremony+"&next=/account", s.cred)
				statuses <- status
			}()
		}
		ok := 0
		for range 2 {
			if <-statuses == http.StatusOK {
				ok++
			}
		}
		assert.Equal(t, 1, ok, "one of the two finishes")
		after, err := e.store.Passkeys(context.Background(), u.ID)
		require.NoError(t, err)
		if purpose == store.PurposeRecover {
			assert.Len(t, after, 1, "recovery leaves exactly the one new passkey")
		} else {
			assert.Len(t, after, len(before)+1, "one passkey per ticket")
		}
	}
}

// A ticket survives a failed attempt to create the passkey (the Owner can try again), and is
// gone after a successful one.
func TestTicketSurvivesAFailedAttempt(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.startEmail(owner, false)
	_, tk := b.confirmCode(e.lastCode(), store.PurposeVerify)
	ticket := tk["ticket"].(string)

	status, begin := b.json("/passkey/register/begin", map[string]string{"ticket": ticket})
	require.Equal(t, http.StatusOK, status)
	status, _ = b.json("/passkey/register/finish?ceremony="+begin["ceremony"].(string), map[string]string{"not": "a credential"})
	assert.Equal(t, http.StatusBadRequest, status)
	status, done := b.createPasskey(ticket)
	require.Equal(t, http.StatusOK, status, done)
	status, _ = b.json("/passkey/register/begin", map[string]string{"ticket": ticket})
	assert.Equal(t, http.StatusBadRequest, status, "used")
}

// When a recovery completes, every other pending recovery of the account ends: a ticket from an
// earlier code (in someone else's hands, perhaps) can no longer add a passkey and throw the
// Owner's new one out.
func TestCompletedRecoveryEndsOtherPendingOnes(t *testing.T) {
	e := setup(t)
	e.browser().signUp()
	u, err := e.store.UserByEmail(context.Background(), owner)
	require.NoError(t, err)

	// Someone reads a recovery code from the Owner's mailbox and gets as far as a ticket, and
	// even starts creating a passkey.
	e.clock.advance(2 * time.Minute)
	intruder := e.browser()
	intruder.startEmail(owner, true)
	e.svc.WaitForMail()
	status, tk := intruder.confirmCode(e.lastCode(), store.PurposeRecover)
	require.Equal(t, http.StatusOK, status, tk)
	stolen := tk["ticket"].(string)
	status, begin := intruder.json("/passkey/register/begin", map[string]string{"ticket": stolen})
	require.Equal(t, http.StatusOK, status)
	cred := intruder.authn.create(t, begin["options"].(map[string]any), e.base)

	// The Owner recovers the account.
	e.clock.advance(2 * time.Minute)
	e.browser().codeFlow(store.PurposeRecover)
	keys, err := e.store.Passkeys(context.Background(), u.ID)
	require.NoError(t, err)
	require.Len(t, keys, 1)

	status, _ = intruder.json("/passkey/register/finish?ceremony="+begin["ceremony"].(string)+"&next=/account", cred)
	assert.Equal(t, http.StatusBadRequest, status, "the registration already started is void")
	status, _ = intruder.json("/passkey/register/begin", map[string]string{"ticket": stolen})
	assert.Equal(t, http.StatusBadRequest, status, "and so is the ticket")
	after, err := e.store.Passkeys(context.Background(), u.ID)
	require.NoError(t, err)
	assert.Equal(t, keys, after, "the Owner's new passkey is the only one")
}

// Passkey sign-ins in progress are kept in memory; their number is capped, and a full table
// answers "try again" rather than growing (FR-099).
func TestCeremoniesAreCapped(t *testing.T) {
	account.SetPendingCap(t, 5)
	e := setup(t)
	b := e.browser()
	for range 5 {
		status, _ := b.json("/passkey/login/begin", map[string]string{"purpose": "signin"})
		require.Equal(t, http.StatusOK, status)
	}
	status, r := b.json("/passkey/login/begin", map[string]string{"purpose": "signin"})
	assert.Equal(t, http.StatusServiceUnavailable, status)
	assert.Equal(t, "Too many sign-ins are in progress right now. Try again in a minute.", r["error"])
	assert.Equal(t, 5, e.svc.PendingCeremonies())

	e.clock.advance(6 * time.Minute) // they expire
	status, _ = b.json("/passkey/login/begin", map[string]string{"purpose": "signin"})
	assert.Equal(t, http.StatusOK, status, "room again once the old ones expired")
	assert.Equal(t, 1, e.svc.PendingCeremonies(), "expired ones are swept, not kept")
}

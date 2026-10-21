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
	macs    *fakeMacs
	clock   *clock
	base    string // http://localhost:<port>
	changed []string
}

func setup(t *testing.T, allowed ...string) *env {
	t.Helper()
	ctx := context.Background()
	st, err := store.Open(ctx, filepath.Join(t.TempDir(), "relay.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = st.Close() })
	e := &env{t: t, store: st, mail: &account.MemoryMailer{}, macs: &fakeMacs{online: map[string]bool{}}, clock: &clock{t: time.Now()}}

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
	svc, err = account.New(ctx, account.Config{
		PublicURL: public, Store: st, Macs: e.macs, Mailer: e.mail, OAuth: o, AllowedEmails: allowed,
		Now: e.clock.now, DevicesChanged: func(id string) { e.changed = append(e.changed, id) },
	})
	require.NoError(t, err)
	auth.svc = svc
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
	linkRE = regexp.MustCompile(`http://localhost:\d+/\S+`)
	csrfRE = regexp.MustCompile(`name="csrf" value="([^"]+)"`)
	tokRE  = regexp.MustCompile(`data-token="([^"]+)"`)
)

func (e *env) lastLink() string {
	e.t.Helper()
	const to = "owner@example.com"
	msgs := e.mail.Sent()
	for i := len(msgs) - 1; i >= 0; i-- {
		if msgs[i].To == to {
			return linkRE.FindString(msgs[i].Body)
		}
	}
	e.t.Fatalf("no email to %s", to)
	return ""
}

func csrf(t *testing.T, body string) string {
	t.Helper()
	m := csrfRE.FindStringSubmatch(body)
	require.NotNil(t, m, "no CSRF token on page")
	return m[1]
}

// createPasskey runs the create-passkey page at link (verify or recover).
func (b *browser) createPasskey(link, purpose string) (int, map[string]any) {
	b.e.t.Helper()
	page := b.get(link)
	require.Equal(b.e.t, http.StatusOK, page.status, page.body)
	tok := tokRE.FindStringSubmatch(page.body)
	require.NotNil(b.e.t, tok)
	status, begin := b.json("/passkey/register/begin", map[string]string{"purpose": purpose, "token": tok[1]})
	require.Equal(b.e.t, http.StatusOK, status, begin)
	cred := b.authn.create(b.e.t, begin["options"].(map[string]any), b.e.base)
	return b.json("/passkey/register/finish?ceremony="+begin["ceremony"].(string)+"&next=/account", cred)
}

func (b *browser) signUp() {
	const email = "owner@example.com"
	b.e.t.Helper()
	r := b.form("/signup", url.Values{"email": {email}})
	require.Equal(b.e.t, http.StatusOK, r.status, r.body)
	status, done := b.createPasskey(b.e.lastLink(), store.PurposeVerify)
	require.Equal(b.e.t, http.StatusOK, status, done)
	assert.Equal(b.e.t, "/account", done["next"])
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

func TestSignUpVerifiesEmailAndCreatesPasskey(t *testing.T) {
	e := setup(t)
	b := e.browser()
	r := b.form("/signup", url.Values{"email": {" Owner@Example.com "}})
	require.Equal(t, http.StatusOK, r.status)
	assert.Contains(t, r.body, "Check your email")
	require.Len(t, e.mail.Sent(), 1)
	assert.Equal(t, "Finish creating your Latchkey account", e.mail.Sent()[0].Subject)

	link := e.lastLink()
	b.get(link) // a mail scanner prefetching the link must not use it up
	status, done := b.createPasskey(link, store.PurposeVerify)
	require.Equal(t, http.StatusOK, status, done)

	u, err := e.store.UserByEmail(context.Background(), "owner@example.com")
	require.NoError(t, err)
	assert.False(t, u.EmailVerifiedAt.IsZero())
	keys, err := e.store.Passkeys(context.Background(), u.ID)
	require.NoError(t, err)
	assert.Len(t, keys, 1)

	page := b.get("/account")
	assert.Equal(t, http.StatusOK, page.status)
	assert.Contains(t, page.body, "owner@example.com")

	// The link is single-use.
	assert.Equal(t, http.StatusBadRequest, b.get(link).status)
}

func TestNoPasswordAnywhere(t *testing.T) {
	e := setup(t)
	b := e.browser()
	for _, p := range []string{"/", "/signup", "/signin", "/recover"} {
		assert.NotContains(t, strings.ToLower(b.get(p).body), `type="password"`, p)
	}
}

func TestSignInWithPasskey(t *testing.T) {
	e := setup(t)
	first := e.browser()
	first.signUp()

	other := e.browser()
	other.authn = first.authn // same passkey, synced to another browser
	assert.Equal(t, http.StatusFound, other.get("/account").status, "not signed in yet")
	status, done := other.signIn("signin", nil)
	require.Equal(t, http.StatusOK, status, done)
	assert.Equal(t, http.StatusOK, other.get("/account").status)
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

func TestSignUpWhenAlreadyRegistered(t *testing.T) {
	e := setup(t)
	e.browser().signUp()
	e.clock.advance(2 * time.Minute)
	r := e.browser().form("/signup", url.Values{"email": {"owner@example.com"}})
	assert.Equal(t, http.StatusOK, r.status, "same answer as a new sign-up")
	msgs := e.mail.Sent()
	assert.Equal(t, "Sign in to Latchkey", msgs[len(msgs)-1].Subject)
}

func TestEmailRateLimit(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.form("/signup", url.Values{"email": {"owner@example.com"}})
	b.form("/signup", url.Values{"email": {"owner@example.com"}})
	assert.Len(t, e.mail.Sent(), 1, "at most one email per minute per address")
	e.clock.advance(61 * time.Second)
	b.form("/signup", url.Values{"email": {"owner@example.com"}})
	assert.Len(t, e.mail.Sent(), 2)
}

func TestAllowedEmails(t *testing.T) {
	e := setup(t, "Toni@example.com")
	r := e.browser().form("/signup", url.Values{"email": {"stranger@example.com"}})
	assert.Equal(t, http.StatusForbidden, r.status)
	assert.Empty(t, e.mail.Sent())
	r = e.browser().form("/signup", url.Values{"email": {"toni@example.com"}})
	assert.Equal(t, http.StatusOK, r.status)
	assert.Len(t, e.mail.Sent(), 1)
}

func TestInvalidEmail(t *testing.T) {
	e := setup(t)
	r := e.browser().form("/signup", url.Values{"email": {"not an email"}})
	assert.Equal(t, http.StatusBadRequest, r.status)
	assert.Contains(t, r.body, "valid email")
}

func TestRecovery(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.signUp()
	oldCred := b.authn.only(t)
	u, err := e.store.UserByEmail(context.Background(), "owner@example.com")
	require.NoError(t, err)
	d, err := e.store.CreateDevice(context.Background(), store.NewDevice{UserID: u.ID, Name: "Mac", PublicKey: []byte("k")}, e.clock.now())
	require.NoError(t, err)
	e.macs.online[d.ID] = true

	lost := e.browser() // the passkeys are gone; a new device
	e.clock.advance(2 * time.Minute)
	r := lost.form("/recover", url.Values{"email": {"owner@example.com"}})
	assert.Equal(t, http.StatusOK, r.status)
	status, done := lost.createPasskey(e.lastLink(), store.PurposeRecover)
	require.Equal(t, http.StatusOK, status, done)
	assert.Equal(t, http.StatusOK, lost.get("/account").status, "signed in with the new passkey")

	keys, err := e.store.Passkeys(context.Background(), u.ID)
	require.NoError(t, err)
	assert.Len(t, keys, 1, "old passkeys removed (FR-047)")
	assert.Equal(t, http.StatusFound, b.get("/account").status, "old sessions signed out")
	status, _ = b.signIn("signin", oldCred)
	assert.Equal(t, http.StatusUnauthorized, status, "the old passkey no longer works")

	msgs := e.mail.Sent()
	assert.Equal(t, "Your Latchkey account was recovered", msgs[len(msgs)-1].Subject, "announced by email")
	require.Len(t, e.macs.notices, 1, "announced on the Mac")
	assert.Equal(t, agentproto.NoticeAccountRecovered, e.macs.notices[0].Kind)
}

func TestRecoveryForUnknownEmailLooksTheSame(t *testing.T) {
	e := setup(t)
	r := e.browser().form("/recover", url.Values{"email": {"nobody@example.com"}})
	assert.Equal(t, http.StatusOK, r.status)
	assert.Contains(t, r.body, "If an account uses this address")
	assert.Empty(t, e.mail.Sent())
}

func TestRecoveryLinkExpires(t *testing.T) {
	e := setup(t)
	e.browser().signUp()
	e.clock.advance(2 * time.Minute)
	e.browser().form("/recover", url.Values{"email": {"owner@example.com"}})
	link := e.lastLink()
	e.clock.advance(16 * time.Minute)
	assert.Equal(t, http.StatusBadRequest, e.browser().get(link).status)
}

func TestNoticesOnConnect(t *testing.T) {
	e := setup(t)
	e.browser().signUp()
	u, _ := e.store.UserByEmail(context.Background(), "owner@example.com")
	d, err := e.store.CreateDevice(context.Background(), store.NewDevice{UserID: u.ID, Name: "Mac", PublicKey: []byte("k")}, e.clock.now())
	require.NoError(t, err)
	connected := e.clock.now()

	e.clock.advance(2 * time.Minute)
	e.browser().form("/recover", url.Values{"email": {"owner@example.com"}})
	e.browser().createPasskey(e.lastLink(), store.PurposeRecover)
	assert.Empty(t, e.macs.notices, "the Mac was offline")

	svc := e.service(t)
	notices := svc.NoticesOnConnect(context.Background(), d, connected)
	require.Len(t, notices, 1, "told on its next connection")
	assert.Empty(t, svc.NoticesOnConnect(context.Background(), d, e.clock.now()), "only once")
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

func TestRevokeMacAndClaude(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.signUp()
	u, _ := e.store.UserByEmail(context.Background(), "owner@example.com")
	d, err := e.store.CreateDevice(context.Background(), store.NewDevice{UserID: u.ID, Name: "Mac", PublicKey: []byte("k")}, e.clock.now())
	require.NoError(t, err)
	require.NoError(t, e.store.PutConsent(context.Background(), u.ID, "cl_x", "mcp", e.clock.now()))

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
	_, err = e.store.Consent(context.Background(), u.ID, "cl_x")
	require.ErrorIs(t, err, store.ErrNotFound)
}

func TestNextIsAlwaysLocal(t *testing.T) {
	e := setup(t)
	page := e.browser().get("/signin?next=//evil.example/x")
	assert.Contains(t, page.body, `data-next="/account"`)
	page = e.browser().get("/signin?next=" + url.QueryEscape("/authorize?client_id=x"))
	assert.Contains(t, page.body, `data-next="/authorize?client_id=x"`)
}

func TestPasskeyEndpointsNeedJSON(t *testing.T) {
	e := setup(t)
	r := e.browser().form("/passkey/login/begin", url.Values{"purpose": {"signin"}})
	assert.Equal(t, http.StatusUnsupportedMediaType, r.status)
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
	assert.Contains(t, page.body, "Allow Claude to use your Mac?")
	assert.Contains(t, page.body, "claude.ai")
	r := b.form("/authorize?"+q.Encode(), url.Values{"csrf": {csrf(t, page.body)}, "decision": {"allow"}})
	require.Contains(t, []int{http.StatusFound, http.StatusSeeOther}, r.status, r.body)
	assert.True(t, strings.HasPrefix(r.header.Get("Location"), "https://claude.ai/api/mcp/auth_callback?code="))
}

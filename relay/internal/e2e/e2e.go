// Package e2e drives a real relay the way an Owner and Claude would: headless Chrome with a
// virtual passkey for the web pages, the OAuth flow for a client, and pairing for a Mac. It is
// used by the end-to-end test and by the local Claude Code check (scripts/claude-code-check.sh).
package e2e

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/chromedp/cdproto/cdp"
	"github.com/chromedp/cdproto/network"
	"github.com/chromedp/cdproto/webauthn"
	"github.com/chromedp/chromedp"
)

// ErrNoChrome means no Chrome or Chromium is installed.
var ErrNoChrome = errors.New("chrome not found")

func chromePath() string {
	if p := os.Getenv("CHROME_PATH"); p != "" {
		return p
	}
	for _, p := range []string{
		"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
		"/Applications/Chromium.app/Contents/MacOS/Chromium",
	} {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	for _, name := range []string{"google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "headless-shell"} {
		if p, err := exec.LookPath(name); err == nil {
			return p
		}
	}
	return ""
}

// Browser is headless Chrome with a virtual platform authenticator (a passkey that always
// verifies the user).
type Browser struct {
	ctx    context.Context
	cancel func()
	email  string // the account SignUp created
}

// NewBrowser starts Chrome.
func NewBrowser(ctx context.Context) (*Browser, error) {
	path := chromePath()
	if path == "" {
		return nil, ErrNoChrome
	}
	opts := append(chromedp.DefaultExecAllocatorOptions[:], chromedp.ExecPath(path))
	actx, cancelAlloc := chromedp.NewExecAllocator(ctx, opts...)
	bctx, cancelBrowser := chromedp.NewContext(actx)
	b := &Browser{ctx: bctx, cancel: func() { cancelBrowser(); cancelAlloc() }}
	err := chromedp.Do(bctx, chromedp.Navigate("about:blank"))
	if err == nil {
		_, err = chromedp.Call(bctx, webauthn.Enable, webauthn.EnableParams{EnableUI: new(false)})
	}
	if err == nil {
		_, err = chromedp.Call(bctx, webauthn.AddVirtualAuthenticator, webauthn.AddVirtualAuthenticatorParams{
			Options: &webauthn.VirtualAuthenticatorOptions{
				Protocol: webauthn.AuthenticatorProtocolCtap2, Transport: webauthn.AuthenticatorTransportInternal,
				HasResidentKey: true, HasUserVerification: true, IsUserVerified: true, AutomaticPresenceSimulation: true,
			},
		})
	}
	if err != nil {
		b.Close()
		return nil, fmt.Errorf("start chrome: %w", err)
	}
	return b, nil
}

// Close stops Chrome.
func (b *Browser) Close() { b.cancel() }

func (b *Browser) run(actions ...chromedp.Action[chromedp.Void]) error {
	ctx, cancel := context.WithTimeout(b.ctx, 15*time.Second)
	defer cancel()
	return chromedp.Do(ctx, actions...)
}

func value[T any](b *Browser, timeout time.Duration, a chromedp.Action[T]) (T, error) {
	ctx, cancel := context.WithTimeout(b.ctx, timeout)
	defer cancel()
	return chromedp.Run(ctx, a)
}

func (b *Browser) location() (string, error) { return value(b, 5*time.Second, chromedp.Location()) }

// waitURL waits until the page location starts with prefix and returns it.
func (b *Browser) waitURL(prefix string) (string, error) {
	deadline := time.Now().Add(15 * time.Second)
	var loc string
	for time.Now().Before(deadline) {
		if l, err := b.location(); err == nil {
			loc = l
			if strings.HasPrefix(loc, prefix) {
				return loc, nil
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	errText, _ := value(b, 2*time.Second, chromedp.Evaluate[string](`(document.getElementById("error")||{}).textContent||""`))
	return "", fmt.Errorf("browser at %q, expected %q (page error: %q)", loc, prefix, errText)
}

// SignUp creates an account on the sign-in page: email, the emailed code (from codeFor), and a
// passkey.
func (b *Browser) SignUp(base, email string, codeFor func(email string) (string, error)) error {
	b.email = email
	if err := b.enterEmail(base + "/signin"); err != nil {
		return fmt.Errorf("sign-in page: %w", err)
	}
	if err := b.run(chromedp.WaitVisible(chromedp.ID("code"))); err != nil {
		return fmt.Errorf("code step: %w", err)
	}
	code, err := codeFor(email)
	if err != nil {
		return err
	}
	if err := b.run(
		chromedp.SendKeys(chromedp.ID("code"), code), // six digits submit by themselves
		chromedp.WaitVisible(chromedp.CSS(`button[data-action=create]`)),
		chromedp.Click(chromedp.CSS(`button[data-action=create]`)),
	); err != nil {
		return fmt.Errorf("create passkey: %w", err)
	}
	_, err = b.waitURL(base + "/account")
	return err
}

// Claim creates a fresh relay's account with its setup code instead of an emailed one (spec 009
// FR-907): the code step must ask for the setup code, which doesn't submit by itself.
func (b *Browser) Claim(base, email, setupCode string) error {
	b.email = email
	if err := b.enterEmail(base + "/signin"); err != nil {
		return fmt.Errorf("sign-in page: %w", err)
	}
	if err := b.run(chromedp.WaitVisible(`//h1[@data-code="setup" and not(@hidden)]`)); err != nil {
		return fmt.Errorf("setup code step: %w", err)
	}
	if err := b.run(
		chromedp.SendKeys(chromedp.ID("code"), setupCode),
		chromedp.Click(chromedp.CSS(`#code-form button[type=submit]`)),
		chromedp.WaitVisible(chromedp.CSS(`button[data-action=create]`)),
		chromedp.Click(chromedp.CSS(`button[data-action=create]`)),
	); err != nil {
		return fmt.Errorf("create passkey: %w", err)
	}
	_, err := b.waitURL(base + "/account")
	return err
}

// RecoverWithCode makes a new passkey on "Lost your passkey?" with a recovery code given by the
// relay's operator (spec 009 FR-914): the code step must ask for that code, not an email.
func (b *Browser) RecoverWithCode(base, code string) error {
	if err := b.enterEmail(base + "/signin?recover=1"); err != nil {
		return fmt.Errorf("recovery page: %w", err)
	}
	if err := b.run(chromedp.WaitVisible(`//h1[@data-code="recovery" and not(@hidden)]`)); err != nil {
		return fmt.Errorf("recovery code step: %w", err)
	}
	if err := b.run(
		chromedp.SendKeys(chromedp.ID("code"), code), // six digits submit by themselves
		chromedp.WaitVisible(chromedp.CSS(`button[data-action=create]`)),
		chromedp.Click(chromedp.CSS(`button[data-action=create]`)),
	); err != nil {
		return fmt.Errorf("create passkey: %w", err)
	}
	_, err := b.waitURL(base + "/account")
	return err
}

// enterEmail opens the sign-in page at url and continues with the Browser's email.
func (b *Browser) enterEmail(url string) error {
	return b.run(
		chromedp.Navigate(url),
		chromedp.WaitVisible(chromedp.ID("email")),
		chromedp.SendKeys(chromedp.ID("email"), b.email),
		chromedp.Click(chromedp.CSS(`#email-form button[type=submit]`)),
	)
}

// passkeyStep signs in on the passkey step of the sign-in page.
func (b *Browser) passkeyStep() error {
	return b.run(
		chromedp.WaitVisible(chromedp.CSS(`button[data-action=signin]`)),
		chromedp.Click(chromedp.CSS(`button[data-action=signin]`)),
	)
}

// SignOut clears the browser's cookies.
func (b *Browser) SignOut() error {
	_, err := chromedp.Call(b.ctx, network.ClearBrowserCookies, cdp.Empty{})
	return err
}

// SignIn signs in with the email and passkey from SignUp.
func (b *Browser) SignIn(base string) error {
	if err := b.run(chromedp.Navigate(base + "/signin")); err != nil {
		return err
	}
	if err := b.signinHere(base); err != nil {
		return err
	}
	_, err := b.waitURL(base + "/account")
	return err
}

// signinHere completes the sign-in page the browser is on. The passkey autofill may finish by
// itself (the virtual authenticator answers it, as a person picking the suggested passkey
// would); otherwise it types the email and uses the passkey button.
func (b *Browser) signinHere(base string) error {
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if loc, err := b.location(); err == nil && !strings.HasPrefix(loc, base+"/signin") {
			return nil // signed in through autofill
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err := b.run(
		chromedp.SendKeys(chromedp.ID("email"), b.email),
		chromedp.Click(chromedp.CSS(`#email-form button[type=submit]`)),
	); err != nil {
		return err
	}
	return b.passkeyStep()
}

// Approve opens an authorization URL, signs in if asked, clicks Allow if asked, and returns
// the URL it was redirected to (which starts with redirectPrefix).
func (b *Browser) Approve(base, authorizeURL, redirectPrefix string) (*url.URL, error) {
	if err := b.run(chromedp.Navigate(authorizeURL)); err != nil && !strings.Contains(err.Error(), "net::ERR") {
		return nil, err
	}
	for range 3 {
		loc, err := b.location()
		if err != nil {
			return nil, err
		}
		switch {
		case strings.HasPrefix(loc, redirectPrefix):
			return url.Parse(loc)
		case strings.HasPrefix(loc, base+"/signin"):
			if err := b.signinHere(base); err != nil {
				return nil, err
			}
			if _, err := b.waitURL(base + "/authorize"); err != nil {
				return nil, err
			}
		case strings.HasPrefix(loc, base+"/authorize"):
			hasButton, _ := value(b, 5*time.Second, chromedp.Evaluate[bool](`!!document.querySelector('button[value=allow]')`))
			if hasButton {
				_ = b.run(chromedp.Click(chromedp.CSS(`button[value=allow]`)))
			}
			loc, err := b.waitURL(redirectPrefix)
			if err != nil {
				return nil, err
			}
			return url.Parse(loc)
		default:
			time.Sleep(200 * time.Millisecond)
		}
	}
	return nil, errors.New("authorization did not finish")
}

// PairCode opens the pairing page, checks it, and returns the pairing code the Connect button
// would hand to the Mac app. The latchkey:// redirect itself is read over HTTP with the
// browser's session, since Chrome cannot follow an unknown scheme.
func (b *Browser) PairCode(base, name string) (string, error) {
	if err := b.run(chromedp.Navigate(base+"/pair?name="+url.QueryEscape(name)),
		chromedp.WaitVisible(`//h1[contains(., "Connect")]`),
	); err != nil {
		return "", fmt.Errorf("pair page: %w", err)
	}
	token, err := value(b, 5*time.Second, chromedp.Value(chromedp.CSS(`input[name=csrf]`)))
	if err != nil {
		return "", err
	}
	res, err := chromedp.Call(b.ctx, network.GetCookies, network.GetCookiesParams{URLs: []string{base}})
	if err != nil {
		return "", err
	}
	cookies := res.Cookies
	req, err := http.NewRequestWithContext(b.ctx, http.MethodPost, base+"/pair", strings.NewReader(url.Values{"csrf": {token}}.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	for _, c := range cookies {
		// nosemgrep: go.lang.security.audit.net.cookie-missing-httponly.cookie-missing-httponly, go.lang.security.audit.net.cookie-missing-secure.cookie-missing-secure -- a request cookie in a test client
		req.AddCookie(&http.Cookie{Name: c.Name, Value: c.Value}) //nolint:gosec // a request cookie; attributes don't apply
	}
	resp, err := noRedirect.Do(req)
	if err != nil {
		return "", err
	}
	_ = resp.Body.Close()
	loc, err := url.Parse(resp.Header.Get("Location"))
	if err != nil || loc.Scheme != "latchkey" || loc.Query().Get("code") == "" {
		return "", fmt.Errorf("pairing redirect %q (HTTP %d)", resp.Header.Get("Location"), resp.StatusCode)
	}
	return loc.Query().Get("code"), nil
}

var noRedirect = &http.Client{
	Timeout:       10 * time.Second,
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

// ExchangePairingCode does what the Mac app does with the code; it returns the device ID.
func ExchangePairingCode(ctx context.Context, base, code string, publicKeyDER []byte, name string) (string, error) {
	body, _ := json.Marshal(map[string]string{
		"code": code, "public_key": base64.RawURLEncoding.EncodeToString(publicKeyDER), "name": name,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/pair/exchange", strings.NewReader(string(body)))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := noRedirect.Do(req)
	if err != nil {
		return "", err
	}
	defer func() { _ = resp.Body.Close() }()
	var out map[string]string
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("pair exchange: HTTP %d: %s", resp.StatusCode, out["error"])
	}
	return out["device_id"], nil
}

// Token runs the OAuth flow by hand (dynamic registration, PKCE, browser approval, code
// exchange) and returns an access token, as a client such as Claude Code would.
func (b *Browser) Token(ctx context.Context, base string) (string, error) {
	cb, err := NewCallback(ctx)
	if err != nil {
		return "", err
	}
	defer cb.Close()
	redirect := cb.URL
	reg, _ := json.Marshal(map[string]any{"client_name": "Claude Code (local check)", "redirect_uris": []string{redirect}, "token_endpoint_auth_method": "none"})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/register", strings.NewReader(string(reg)))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := noRedirect.Do(req)
	if err != nil {
		return "", err
	}
	var client map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&client)
	_ = resp.Body.Close()
	clientID, _ := client["client_id"].(string)
	if clientID == "" {
		return "", fmt.Errorf("registration failed: %v", client)
	}

	verifierBytes := make([]byte, 32)
	_, _ = rand.Read(verifierBytes)
	verifier := base64.RawURLEncoding.EncodeToString(verifierBytes)
	sum := sha256.Sum256([]byte(verifier))
	q := url.Values{
		"response_type": {"code"}, "client_id": {clientID}, "redirect_uri": {redirect},
		"scope": {"mcp offline_access"}, "state": {"local-check-state"}, "resource": {base + "/mcp"},
		"code_challenge": {base64.RawURLEncoding.EncodeToString(sum[:])}, "code_challenge_method": {"S256"},
	}
	loc, err := b.Approve(base, base+"/authorize?"+q.Encode(), redirect)
	if err != nil {
		return "", err
	}
	code := loc.Query().Get("code")
	if code == "" {
		return "", fmt.Errorf("no code in %s", loc)
	}
	form := url.Values{
		"grant_type": {"authorization_code"}, "code": {code}, "redirect_uri": {redirect},
		"client_id": {clientID}, "code_verifier": {verifier},
	}
	req, err = http.NewRequestWithContext(ctx, http.MethodPost, base+"/token", strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err = noRedirect.Do(req)
	if err != nil {
		return "", err
	}
	defer func() { _ = resp.Body.Close() }()
	var tok map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&tok)
	access, _ := tok["access_token"].(string)
	if access == "" {
		return "", fmt.Errorf("token exchange failed: %v", tok)
	}
	return access, nil
}

// Callback is a loopback redirect target, as Claude Code runs during sign-in.
type Callback struct {
	URL   string // http://localhost:<port>/callback
	close func()
}

// NewCallback listens on a free localhost port.
func NewCallback(ctx context.Context) (*Callback, error) {
	l, err := (&net.ListenConfig{}).Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	srv := &http.Server{
		Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte("Signed in. You can close this tab.\n"))
		}),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() { _ = srv.Serve(l) }()
	return &Callback{URL: fmt.Sprintf("http://localhost:%d/callback", l.Addr().(*net.TCPAddr).Port), close: func() { _ = srv.Close() }}, nil
}

// Close stops listening.
func (c *Callback) Close() { c.close() }

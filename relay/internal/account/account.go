// Package account is the Owner's side of the relay (plan D5, D6): sign-up with email
// verification, passkey sign-in, recovery, the account page, the consent page for Claude, and
// pairing a Mac.
package account

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"embed"
	"encoding/base64"
	"errors"
	"html/template"
	"io/fs"
	"log/slog"
	"net/http"
	"net/mail"
	"net/url"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/go-webauthn/webauthn/webauthn"

	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/oauth"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

const (
	sessionLifetime = 30 * 24 * time.Hour // FR-048
	linkLifetime    = 15 * time.Minute    // email links (plan D5)
	pairingLifetime = 5 * time.Minute     // pairing codes (data-model.md)
	reauthWindow    = 5 * time.Minute     // fresh passkey check before deleting the account
	emailInterval   = time.Minute         // at most one email per address per minute
)

//go:embed templates/*.html
var templateFS embed.FS

//go:embed static
var staticFS embed.FS

// Macs is what the account pages need from the hub.
type Macs interface {
	Online(deviceID string) bool
	Revoke(deviceID string)
	SendNotice(ctx context.Context, deviceID string, n *agentproto.Notice) error
}

// Config configures the service.
type Config struct {
	PublicURL     *url.URL
	Store         *store.Store
	Macs          Macs
	Mailer        Mailer
	OAuth         *oauth.Server
	AllowedEmails []string // empty: open sign-up (FR-046)
	Now           func() time.Time
	Logger        *slog.Logger
	// DevicesChanged is called after a Mac is revoked or replaced, so Claude's tool list updates.
	DevicesChanged func(userID string)
}

// Service serves the account pages and implements oauth.Authenticator.
type Service struct {
	cfg      Config
	webauthn *webauthn.WebAuthn
	pages    *template.Template
	csrfKey  []byte
	secure   bool
	cookie   string

	mu         sync.Mutex
	ceremonies map[string]*ceremony
	lastEmail  map[string]time.Time
}

// New creates the service.
func New(ctx context.Context, cfg Config) (*Service, error) {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	if cfg.DevicesChanged == nil {
		cfg.DevicesChanged = func(string) {}
	}
	origin := strings.TrimSuffix(cfg.PublicURL.String(), "/")
	wa, err := webauthn.New(&webauthn.Config{
		RPID:          cfg.PublicURL.Hostname(),
		RPDisplayName: "Latchkey",
		RPOrigins:     []string{origin},
	})
	if err != nil {
		return nil, err
	}
	key, err := cfg.Store.KeyOrCreate(ctx, "csrf", func() ([]byte, error) {
		b := make([]byte, 32)
		_, err := rand.Read(b)
		return b, err
	})
	if err != nil {
		return nil, err
	}
	pages, err := template.New("").Funcs(template.FuncMap{
		"when": func(t time.Time) string { return t.UTC().Format("Jan 2, 2006, 3:04 PM") + " UTC" },
		"ms":   func(d time.Duration) int64 { return d.Milliseconds() },
	}).ParseFS(templateFS, "templates/*.html")
	if err != nil {
		return nil, err
	}
	secure := cfg.PublicURL.Scheme == "https"
	cookie := "latchkey_session"
	if secure {
		cookie = "__Host-latchkey_session"
	}
	for i, e := range cfg.AllowedEmails {
		cfg.AllowedEmails[i] = normalizeEmail(e)
	}
	return &Service{
		cfg: cfg, webauthn: wa, pages: pages, csrfKey: key, secure: secure, cookie: cookie,
		ceremonies: map[string]*ceremony{}, lastEmail: map[string]time.Time{},
	}, nil
}

// Register mounts the account pages.
func (s *Service) Register(mux *http.ServeMux) {
	static, _ := fs.Sub(staticFS, "static")
	mux.Handle("GET /static/", http.StripPrefix("/static/", http.FileServerFS(static)))
	mux.HandleFunc("GET /{$}", s.home)
	mux.HandleFunc("GET /signup", s.signupPage)
	mux.HandleFunc("POST /signup", s.signup)
	mux.HandleFunc("GET /verify", s.verifyPage)
	mux.HandleFunc("GET /signin", s.signinPage)
	mux.HandleFunc("POST /signout", s.signout)
	mux.HandleFunc("GET /recover", s.recoverPage)
	mux.HandleFunc("POST /recover", s.recover)
	mux.HandleFunc("GET /recover/confirm", s.recoverConfirmPage)
	mux.HandleFunc("POST /passkey/register/begin", s.registerBegin)
	mux.HandleFunc("POST /passkey/register/finish", s.registerFinish)
	mux.HandleFunc("POST /passkey/login/begin", s.loginBegin)
	mux.HandleFunc("POST /passkey/login/finish", s.loginFinish)
	mux.HandleFunc("GET /account", s.accountPage)
	mux.HandleFunc("POST /account/revoke-mac", s.revokeMac)
	mux.HandleFunc("POST /account/revoke-claude", s.revokeClaude)
	mux.HandleFunc("POST /account/delete", s.deleteAccount)
	mux.HandleFunc("GET /pair", s.pairPage)
	mux.HandleFunc("POST /pair", s.pair)
	mux.HandleFunc("POST /pair/exchange", s.pairExchange)
}

func (s *Service) now() time.Time { return s.cfg.Now().UTC() }

func hash(v string) []byte {
	h := sha256.Sum256([]byte(v))
	return h[:]
}

func randomToken() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b) // never fails (crypto/rand)
	return base64.RawURLEncoding.EncodeToString(b)
}

func normalizeEmail(e string) string { return strings.ToLower(strings.TrimSpace(e)) }

func validEmail(e string) bool {
	a, err := mail.ParseAddress(e)
	return err == nil && a.Address == e && strings.Contains(e, "@")
}

// safeNext keeps redirects on this site.
func safeNext(next string) string {
	if next == "" || !strings.HasPrefix(next, "/") || strings.HasPrefix(next, "//") || strings.HasPrefix(next, "/\\") {
		return "/account"
	}
	return next
}

// --- sessions and CSRF ---

func (s *Service) sessionToken(r *http.Request) string {
	c, err := r.Cookie(s.cookie)
	if err != nil {
		return ""
	}
	return c.Value
}

func (s *Service) session(r *http.Request) (store.Session, string, bool) {
	tok := s.sessionToken(r)
	if tok == "" {
		return store.Session{}, "", false
	}
	sess, err := s.cfg.Store.Session(r.Context(), hash(tok), s.now())
	if err != nil {
		return store.Session{}, "", false
	}
	return sess, tok, true
}

// CurrentUser implements oauth.Authenticator.
func (s *Service) CurrentUser(r *http.Request) (string, bool) {
	sess, _, ok := s.session(r)
	return sess.UserID, ok
}

// SignIn implements oauth.Authenticator.
func (s *Service) SignIn(w http.ResponseWriter, r *http.Request) {
	http.Redirect(w, r, "/signin?next="+url.QueryEscape(r.URL.RequestURI()), http.StatusFound)
}

func (s *Service) startSession(w http.ResponseWriter, r *http.Request, userID string) error {
	tok := randomToken()
	now := s.now()
	if err := s.cfg.Store.CreateSession(r.Context(), hash(tok), userID, now, now.Add(sessionLifetime)); err != nil {
		return err
	}
	http.SetCookie(w, &http.Cookie{ //nolint:gosec // Secure is set whenever the relay runs on https
		Name: s.cookie, Value: tok, Path: "/", MaxAge: int(sessionLifetime / time.Second),
		HttpOnly: true, Secure: s.secure, SameSite: http.SameSiteLaxMode,
	})
	return nil
}

func (s *Service) clearSession(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{ //nolint:gosec // as above
		Name: s.cookie, Value: "", Path: "/", MaxAge: -1, HttpOnly: true, Secure: s.secure, SameSite: http.SameSiteLaxMode,
	})
}

func (s *Service) csrfFor(sessionToken string) string {
	m := hmac.New(sha256.New, s.csrfKey)
	m.Write([]byte("csrf\n" + sessionToken))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

// ValidCSRF implements oauth.Authenticator.
func (s *Service) ValidCSRF(r *http.Request) bool {
	tok := s.sessionToken(r)
	if tok == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(r.PostFormValue("csrf")), []byte(s.csrfFor(tok))) == 1
}

// requireUser returns the signed-in user or sends the browser to sign in.
func (s *Service) requireUser(w http.ResponseWriter, r *http.Request) (store.User, string, bool) {
	sess, tok, ok := s.session(r)
	if ok {
		u, err := s.cfg.Store.User(r.Context(), sess.UserID)
		if err == nil {
			return u, tok, true
		}
	}
	s.SignIn(w, r)
	return store.User{}, "", false
}

// --- pages ---

type page struct {
	Title    string
	CSRF     string
	Next     string
	Email    string
	Message  string
	Error    string
	Data     any
	SignedIn bool
}

func (s *Service) render(w http.ResponseWriter, status int, name string, p page) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Content-Security-Policy", "default-src 'self'; frame-ancestors 'none'; form-action 'self' https: http://localhost:* http://127.0.0.1:* latchkey:")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.WriteHeader(status)
	if err := s.pages.ExecuteTemplate(w, name, p); err != nil {
		s.cfg.Logger.Error("render page", "page", name, "err", err)
	}
}

func (s *Service) errorPage(w http.ResponseWriter, status int, title, msg string) {
	s.render(w, status, "message.html", page{Title: title, Message: msg})
}

func (s *Service) home(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.CurrentUser(r); ok {
		http.Redirect(w, r, "/account", http.StatusFound)
		return
	}
	s.render(w, http.StatusOK, "home.html", page{Title: "Latchkey"})
}

func (s *Service) signupPage(w http.ResponseWriter, r *http.Request) {
	s.render(w, http.StatusOK, "signup.html", page{Title: "Create your account", Next: safeNext(r.URL.Query().Get("next"))})
}

// allowEmail limits how often one address can be emailed.
func (s *Service) allowEmail(addr string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	if last, ok := s.lastEmail[addr]; ok && now.Sub(last) < emailInterval {
		return false
	}
	s.lastEmail[addr] = now
	for a, t := range s.lastEmail {
		if now.Sub(t) > emailInterval {
			delete(s.lastEmail, a)
		}
	}
	return true
}

func (s *Service) link(path string, q url.Values) string {
	u := *s.cfg.PublicURL
	u.Path = path
	u.RawQuery = q.Encode()
	return u.String()
}

func (s *Service) signup(w http.ResponseWriter, r *http.Request) {
	email := normalizeEmail(r.PostFormValue("email"))
	next := safeNext(r.PostFormValue("next"))
	if !validEmail(email) {
		s.render(w, http.StatusBadRequest, "signup.html", page{Title: "Create your account", Email: email, Next: next, Error: "Enter a valid email address."})
		return
	}
	if len(s.cfg.AllowedEmails) > 0 && !slices.Contains(s.cfg.AllowedEmails, email) {
		s.render(w, http.StatusForbidden, "signup.html", page{
			Title: "Create your account", Email: email, Next: next,
			Error: "This relay only accepts sign-ups from approved email addresses.",
		})
		return
	}
	ctx := r.Context()
	if s.allowEmail(email) {
		if err := s.sendSignupEmail(ctx, email, next); err != nil {
			s.cfg.Logger.Error("sign-up email", "err", err)
			s.errorPage(w, http.StatusBadGateway, "Email not sent", "The relay couldn't send email right now. Try again in a few minutes.")
			return
		}
	}
	s.render(w, http.StatusOK, "check-email.html", page{Title: "Check your email", Email: email})
}

func (s *Service) sendSignupEmail(ctx context.Context, email, next string) error {
	u, err := s.cfg.Store.UserByEmail(ctx, email)
	switch {
	case errors.Is(err, store.ErrNotFound):
		if u, err = s.cfg.Store.CreateUser(ctx, email, s.now()); err != nil {
			return err
		}
	case err != nil:
		return err
	case !u.EmailVerifiedAt.IsZero():
		return s.cfg.Mailer.Send(ctx, email, "Sign in to Latchkey", emailAlreadyRegistered(s.link("/signin", nil), s.link("/recover", nil)))
	}
	tok := randomToken()
	if err := s.cfg.Store.CreateEmailToken(ctx, hash(tok), u.ID, store.PurposeVerify, s.now().Add(linkLifetime)); err != nil {
		return err
	}
	return s.cfg.Mailer.Send(ctx, email, "Finish creating your Latchkey account",
		emailVerify(s.link("/verify", url.Values{"token": {tok}, "next": {next}})))
}

func (s *Service) verifyPage(w http.ResponseWriter, r *http.Request) {
	s.passkeyPage(w, r, store.PurposeVerify, "Create your passkey",
		"Your email is confirmed. Create a passkey to finish setting up your account. You'll use it to sign in; there is no password.")
}

func (s *Service) recoverConfirmPage(w http.ResponseWriter, r *http.Request) {
	s.passkeyPage(w, r, store.PurposeRecover, "Create a new passkey",
		"Create a new passkey for your account. Your old passkeys will stop working.")
}

func (s *Service) passkeyPage(w http.ResponseWriter, r *http.Request, purpose, title, msg string) {
	tok := r.URL.Query().Get("token")
	userID, err := s.cfg.Store.PeekEmailToken(r.Context(), hash(tok), purpose, s.now())
	if err != nil {
		s.errorPage(w, http.StatusBadRequest, "This link has expired",
			"Links work once and expire after 15 minutes. Start again to get a new one.")
		return
	}
	u, err := s.cfg.Store.User(r.Context(), userID)
	if err != nil {
		s.errorPage(w, http.StatusBadRequest, "This link has expired", "Start again to get a new one.")
		return
	}
	s.render(w, http.StatusOK, "create-passkey.html", page{
		Title: title, Message: msg, Email: u.Email, Next: safeNext(r.URL.Query().Get("next")),
		Data: map[string]string{"Token": tok, "Purpose": purpose},
	})
}

func (s *Service) signinPage(w http.ResponseWriter, r *http.Request) {
	s.render(w, http.StatusOK, "signin.html", page{Title: "Sign in", Next: safeNext(r.URL.Query().Get("next"))})
}

func (s *Service) signout(w http.ResponseWriter, r *http.Request) {
	if !s.ValidCSRF(r) {
		s.errorPage(w, http.StatusForbidden, "This form expired", "Go back, reload the page, and try again.")
		return
	}
	if tok := s.sessionToken(r); tok != "" {
		_ = s.cfg.Store.DeleteSession(r.Context(), hash(tok))
	}
	s.clearSession(w)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (s *Service) recoverPage(w http.ResponseWriter, _ *http.Request) {
	s.render(w, http.StatusOK, "recover.html", page{Title: "Recover your account"})
}

func (s *Service) recover(w http.ResponseWriter, r *http.Request) {
	email := normalizeEmail(r.PostFormValue("email"))
	if !validEmail(email) {
		s.render(w, http.StatusBadRequest, "recover.html", page{Title: "Recover your account", Email: email, Error: "Enter a valid email address."})
		return
	}
	ctx := r.Context()
	// The answer is the same whether or not an account exists.
	if u, err := s.cfg.Store.UserByEmail(ctx, email); err == nil && !u.EmailVerifiedAt.IsZero() && s.allowEmail(email) {
		tok := randomToken()
		if err := s.cfg.Store.CreateEmailToken(ctx, hash(tok), u.ID, store.PurposeRecover, s.now().Add(linkLifetime)); err == nil {
			if err := s.cfg.Mailer.Send(ctx, email, "Recover your Latchkey account",
				emailRecover(s.link("/recover/confirm", url.Values{"token": {tok}}))); err != nil {
				s.cfg.Logger.Error("recovery email", "err", err)
			}
		}
	}
	s.render(w, http.StatusOK, "check-email.html", page{
		Title: "Check your email", Email: email,
		Message: "If an account uses this address, we sent it a recovery link.",
	})
}

// NoticesOnConnect tells a Mac about recoveries since it last connected (plan D5).
func (s *Service) NoticesOnConnect(ctx context.Context, d store.Device, previous time.Time) []*agentproto.Notice {
	if previous.IsZero() {
		previous = d.CreatedAt
	}
	times, err := s.cfg.Store.RecoveriesSince(ctx, d.UserID, previous)
	if err != nil || len(times) == 0 {
		return nil
	}
	return []*agentproto.Notice{{Kind: agentproto.NoticeAccountRecovered, At: times[len(times)-1].Truncate(time.Second)}}
}

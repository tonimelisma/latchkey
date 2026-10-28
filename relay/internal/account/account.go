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
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io/fs"
	"log/slog"
	"math/big"
	"net/http"
	"net/mail"
	"net/url"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/go-webauthn/webauthn/webauthn"

	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/events"
	"github.com/tonimelisma/latchkey/relay/internal/limit"
	"github.com/tonimelisma/latchkey/relay/internal/oauth"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

const (
	sessionLifetime = 30 * 24 * time.Hour // FR-048
	linkLifetime    = 15 * time.Minute    // email codes (plan D5)
	pairingLifetime = 5 * time.Minute     // pairing codes (data-model.md)
	reauthWindow    = 5 * time.Minute     // fresh passkey check before deleting the account
	emailInterval   = time.Minute         // at most one email per address per minute
	emailBurst      = 5                   // then, per address, at most one more every emailRefill
	emailRefill     = 10 * time.Minute
	sendBurst       = 100 // emails the whole relay sends at once, then one every sendRefill
	sendRefill      = 30 * time.Second
	// Recovery codes are sent in the background: at most this many at once, each given this long.
	maxBackgroundSends    = 16
	backgroundSendTimeout = 30 * time.Second
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
	// AccessRemoved is called after every Claude client's access to the account ended (removed
	// by the Owner, by a recovery, or with the account), so what the relay holds in memory for
	// Claude's sessions can go too.
	AccessRemoved func(userID string)
	// Operator is who runs this relay; with a name and a contact, the terms and the privacy
	// policy are published (FR-193).
	Operator Operator
	// Events records sign-in attempts and their outcomes, pairings, and unpairings (FR-631).
	// Nil records nothing.
	Events *events.Recorder
}

// Service serves the account pages and implements oauth.Authenticator.
type Service struct {
	cfg      Config
	webauthn *webauthn.WebAuthn
	pages    *template.Template
	csrfKey  []byte
	secure   bool
	cookie   string

	// Recovery codes are emailed in the background (FR-042b): background counts the sends in
	// flight, sending bounds them.
	background sync.WaitGroup
	sending    chan struct{}

	mu         sync.Mutex
	swept      time.Time // last sweep of ceremonies and tickets
	ceremonies map[string]*ceremony
	tickets    map[string]*ticket
	lastEmail  map[string]time.Time
	perAddress *limit.Keyed // codes per address: guessing and inbox flooding
	allSends   *limit.Keyed // emails from the relay: the sending service's quota
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
	if cfg.AccessRemoved == nil {
		cfg.AccessRemoved = func(string) {}
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
		sending:    make(chan struct{}, maxBackgroundSends),
		ceremonies: map[string]*ceremony{}, tickets: map[string]*ticket{}, lastEmail: map[string]time.Time{},
		perAddress: limit.NewKeyed(emailBurst, emailRefill), allSends: limit.NewKeyed(sendBurst, sendRefill),
	}, nil
}

// Register mounts the account pages.
func (s *Service) Register(mux *http.ServeMux) {
	static, _ := fs.Sub(staticFS, "static")
	mux.Handle("GET /static/", http.StripPrefix("/static/", http.FileServerFS(static)))
	mux.HandleFunc("GET /{$}", s.home)
	mux.HandleFunc("GET /signin", s.signinPage)
	mux.HandleFunc("GET /terms", s.legalPage("terms.html", "Terms of Service"))
	mux.HandleFunc("GET /privacy", s.legalPage("privacy.html", "Privacy Policy"))
	mux.HandleFunc("GET /signup", s.toSignin(false))
	mux.HandleFunc("GET /recover", s.toSignin(true))
	mux.HandleFunc("POST /auth/email", s.authEmail)
	mux.HandleFunc("POST /auth/code", s.authCode)
	mux.HandleFunc("POST /signout", s.signout)
	mux.HandleFunc("POST /passkey/register/begin", s.registerBegin)
	mux.HandleFunc("POST /passkey/register/finish", s.registerFinish)
	mux.HandleFunc("POST /passkey/login/begin", s.loginBegin)
	mux.HandleFunc("POST /passkey/login/finish", s.loginFinish)
	mux.HandleFunc("GET /account", s.accountPage)
	mux.HandleFunc("POST /account/revoke-mac", s.revokeMac)
	mux.HandleFunc("POST /account/revoke-claude", s.revokeClaude)
	mux.HandleFunc("POST /account/revoke-client", s.revokeClient)
	mux.HandleFunc("POST /account/delete", s.deleteAccount)
	mux.HandleFunc("GET /pair", s.pairPage)
	mux.HandleFunc("POST /pair", s.pair)
	mux.HandleFunc("POST /pair/preview", s.pairPreview)
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

// NormalizeEmail is how an address is compared everywhere: as sign-up stores it. The
// operator's commands use it, so `account suspend Owner@Example.com` finds the account.
func NormalizeEmail(e string) string { return normalizeEmail(e) }

// ValidEmail reports whether e is one plain email address, as sign-up requires.
func ValidEmail(e string) bool { return validEmail(e) }

// refused says why an address or account can't sign in, sign up, or recover: the relay's
// operator blocked the address or suspended the account (FR-196, FR-197). Empty means it can.
// The message names the operator's contact address when one is set.
func (s *Service) refused(ctx context.Context, email string, u *store.User) string {
	if blocked, err := s.cfg.Store.EmailBlocked(ctx, email); err == nil && blocked {
		return "This email address can't be used on this relay." + s.contactSentence()
	}
	if u != nil && !u.SuspendedAt.IsZero() {
		return "This account has been suspended by the person who runs this relay." + s.contactSentence()
	}
	return ""
}

func validEmail(e string) bool {
	a, err := mail.ParseAddress(e)
	return err == nil && a.Address == e && strings.Contains(e, "@")
}

// safeNext keeps redirects on this site: a path on this origin, or /account. Browsers drop tab
// and newline from a URL and read a backslash as a slash, so a value with either, or any other
// control character, is refused before parsing (security scan, CWE-601).
func safeNext(next string) string {
	const fallback = "/account"
	if strings.ContainsFunc(next, func(r rune) bool { return r < 0x20 || r == 0x7f || r == '\\' }) {
		return fallback
	}
	u, err := url.Parse(next)
	if err != nil || u.Scheme != "" || u.Host != "" || u.User != nil || u.Opaque != "" ||
		!strings.HasPrefix(next, "/") || strings.HasPrefix(next, "//") {
		return fallback
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
	// nosemgrep: go.lang.security.injection.open-redirect.open-redirect -- fixed local path; next is escaped
	http.Redirect(w, r, "/signin?next="+url.QueryEscape(r.URL.RequestURI()), http.StatusFound)
}

func (s *Service) startSession(w http.ResponseWriter, r *http.Request, userID string) error {
	tok := randomToken()
	now := s.now()
	if err := s.cfg.Store.CreateSession(r.Context(), hash(tok), userID, now, now.Add(sessionLifetime)); err != nil {
		return err
	}
	// nosemgrep: go.lang.security.audit.net.cookie-missing-secure.cookie-missing-secure -- Secure is s.secure
	http.SetCookie(w, &http.Cookie{ //nolint:gosec // Secure is set whenever the relay runs on https
		Name: s.cookie, Value: tok, Path: "/", MaxAge: int(sessionLifetime / time.Second),
		HttpOnly: true, Secure: s.secure, SameSite: http.SameSiteLaxMode,
	})
	return nil
}

func (s *Service) clearSession(w http.ResponseWriter) {
	// nosemgrep: go.lang.security.audit.net.cookie-missing-secure.cookie-missing-secure -- Secure is s.secure
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
	Wide     bool // the account page needs room for its table
	Legal    bool // the footer links the terms and the privacy policy (set by render)
	Plain    bool // a document: no script is loaded
}

func (s *Service) render(w http.ResponseWriter, status int, name string, p page) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Content-Security-Policy", "default-src 'self'; frame-ancestors 'none'; form-action 'self' https: http://localhost:* http://127.0.0.1:* latchkey:")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.WriteHeader(status)
	p.Legal = s.cfg.Operator.Published()
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

// signinPage is the one page for signing in, creating an account, and recovering it: email
// first, then a passkey for a known account or an emailed code for a new one (FR-041 to FR-043).
func (s *Service) signinPage(w http.ResponseWriter, r *http.Request) {
	s.render(w, http.StatusOK, "signin.html", page{
		Title: "Sign in to Latchkey", Next: safeNext(r.URL.Query().Get("next")),
		Data: map[string]bool{"Recover": r.URL.Query().Get("recover") == "1"},
	})
}

// legacy addresses from earlier versions and emails lead to the same page.
func (s *Service) toSignin(recover bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		q := url.Values{"next": {safeNext(r.URL.Query().Get("next"))}}
		if recover {
			q.Set("recover", "1")
		}
		// nosemgrep: go.lang.security.injection.open-redirect.open-redirect -- fixed local path; next passed safeNext
		http.Redirect(w, r, "/signin?"+q.Encode(), http.StatusFound)
	}
}

// allowEmail limits how often one address can be emailed.
func (s *Service) allowEmail(addr string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	if last, ok := s.lastEmail[addr]; ok && now.Sub(last) < emailInterval {
		return false
	}
	if !s.perAddress.AllowAt(addr, now) || !s.allSends.AllowAt("", now) {
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

func newCode() string {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		panic(err) // crypto/rand never fails
	}
	return fmt.Sprintf("%06d", n.Int64())
}

// codeHash binds a code to its user, so two users' codes never collide.
func codeHash(userID, code string) []byte { return hash(userID + ":" + code) }

type emailRequest struct {
	Email   string `json:"email"`
	Recover bool   `json:"recover"`
}

// authEmail is the first step: known accounts continue with a passkey; new ones (and
// recoveries) get a code by email.
func (s *Service) authEmail(w http.ResponseWriter, r *http.Request) {
	if !requireJSON(w, r) {
		return
	}
	var req emailRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		jsonError(w, http.StatusBadRequest, "Bad request.")
		return
	}
	email := normalizeEmail(req.Email)
	if !validEmail(email) {
		jsonError(w, http.StatusBadRequest, "Enter a valid email address.")
		return
	}
	ctx := r.Context()
	u, err := s.cfg.Store.UserByEmail(ctx, email)
	known := err == nil && !u.EmailVerifiedAt.IsZero()
	// A blocked address or a suspended account is told so, for sign-in, sign-up, and recovery
	// alike. (Recovery otherwise answers the same for every address, FR-042b; this reveals only
	// an account the operator suspended.)
	var found *store.User
	if err == nil {
		found = &u
	}
	if msg := s.refused(ctx, email, found); msg != "" {
		kind := events.SignInCode
		if req.Recover {
			kind = events.Recovery
		} else if known {
			kind = events.SignInPasskey
		}
		s.attempt(ctx, kind, accountOf(found), "refused: address blocked or account suspended")
		jsonError(w, http.StatusForbidden, msg)
		return
	}
	if req.Recover {
		if known {
			s.attempt(ctx, events.Recovery, u.ID, "recovery code requested")
		} else {
			s.attempt(ctx, events.Recovery, "", "recovery code requested for an address without an account")
		}
		// The answer never reveals whether the account exists: the same words, and the same
		// speed, because the code is stored and emailed after the answer, not before it
		// (talking to the mail server takes far longer than finding no account).
		if known {
			s.sendCodeInBackground(ctx, u, store.PurposeRecover)
		}
		writeJSON(w, http.StatusOK, map[string]string{"step": "code", "purpose": store.PurposeRecover})
		return
	}
	if known {
		writeJSON(w, http.StatusOK, map[string]string{"step": "passkey"})
		return
	}
	if len(s.cfg.AllowedEmails) > 0 && !slices.Contains(s.cfg.AllowedEmails, email) {
		s.attempt(ctx, events.SignInCode, "", "refused: sign-up from an address not on the relay's list")
		jsonError(w, http.StatusForbidden, "This relay only accepts sign-ups from approved email addresses.")
		return
	}
	if errors.Is(err, store.ErrNotFound) {
		if u, err = s.cfg.Store.CreateUser(ctx, email, s.now()); err != nil {
			jsonError(w, http.StatusInternalServerError, "Something went wrong. Try again.")
			return
		}
	} else if err != nil {
		jsonError(w, http.StatusInternalServerError, "Something went wrong. Try again.")
		return
	}
	if !s.sendCode(ctx, u, store.PurposeVerify) {
		s.attempt(ctx, events.SignInCode, "", "sign-up code could not be emailed")
		jsonError(w, http.StatusBadGateway, "The relay couldn't send email right now. Try again in a few minutes.")
		return
	}
	s.attempt(ctx, events.SignInCode, "", "sign-up code emailed")
	writeJSON(w, http.StatusOK, map[string]string{"step": "code", "purpose": store.PurposeVerify})
}

// sendCodeInBackground runs sendCode after the request has been answered, with its own time
// limit; a failure is only logged (sendCode logs it), as the request can't report it without
// revealing that the account exists. At most maxBackgroundSends run at once; beyond that the
// code is not sent, and the Owner asks again.
func (s *Service) sendCodeInBackground(ctx context.Context, u store.User, purpose string) {
	select {
	case s.sending <- struct{}{}:
	default:
		s.cfg.Logger.Warn("recovery code not sent: too many emails in progress")
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), backgroundSendTimeout)
	s.background.Go(func() {
		defer cancel()
		defer func() { <-s.sending }()
		s.sendCode(ctx, u, purpose)
	})
}

// sendCode emails a fresh code, at most once a minute per address. It reports false only when
// sending failed; a rate-limited request keeps the earlier code valid. While codes for the
// address are refused (FR-042a), none is sent; entering any code then says why.
func (s *Service) sendCode(ctx context.Context, u store.User, purpose string) bool {
	if s.cfg.Store.EmailCodesLocked(ctx, u.ID, s.now()) || !s.allowEmail(u.Email) {
		return true
	}
	code := newCode()
	if err := s.cfg.Store.CreateEmailCode(ctx, u.ID, purpose, codeHash(u.ID, code), s.now().Add(linkLifetime)); err != nil {
		s.cfg.Logger.Error("store email code", "err", err)
		return false
	}
	subject, body := "Your Latchkey code: "+code, emailVerifyCode(code)
	if purpose == store.PurposeRecover {
		subject, body = "Your Latchkey recovery code: "+code, emailRecoverCode(code)
	}
	if err := s.cfg.Mailer.Send(ctx, u.Email, subject, body); err != nil {
		s.cfg.Logger.Error("send email code", "err", err)
		return false
	}
	return true
}

type codeRequest struct {
	Email   string `json:"email"`
	Code    string `json:"code"`
	Purpose string `json:"purpose"`
}

// authCode checks an emailed code and returns a ticket for creating the passkey.
func (s *Service) authCode(w http.ResponseWriter, r *http.Request) {
	if !requireJSON(w, r) {
		return
	}
	var req codeRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil ||
		(req.Purpose != store.PurposeVerify && req.Purpose != store.PurposeRecover) {
		jsonError(w, http.StatusBadRequest, "Bad request.")
		return
	}
	expired := "This code has expired or was tried too many times. Go back and get a new code."
	ctx := r.Context()
	kind := events.SignInCode
	if req.Purpose == store.PurposeRecover {
		kind = events.Recovery
	}
	u, err := s.cfg.Store.UserByEmail(ctx, normalizeEmail(req.Email))
	if err != nil {
		s.attempt(ctx, kind, "", "code refused: no such account")
		jsonError(w, http.StatusBadRequest, expired)
		return
	}
	if msg := s.refused(ctx, u.Email, &u); msg != "" {
		s.attempt(ctx, kind, accountOf(&u), "code refused: address blocked or account suspended")
		jsonError(w, http.StatusForbidden, msg)
		return
	}
	code := strings.Join(strings.Fields(req.Code), "")
	switch err := s.cfg.Store.CheckEmailCode(ctx, u.ID, req.Purpose, codeHash(u.ID, code), s.now()); {
	case errors.Is(err, store.ErrCodesLocked):
		s.attempt(ctx, kind, accountOf(&u), "code refused: too many wrong codes today")
		jsonError(w, http.StatusTooManyRequests,
			"Too many wrong codes were entered for this email address today. Sign in with your passkey, or try again tomorrow.")
		return
	case errors.Is(err, store.ErrWrongCode):
		s.attempt(ctx, kind, accountOf(&u), "code refused: wrong code")
		jsonError(w, http.StatusBadRequest, "That code isn't right. Check the email and try again.")
		return
	case err != nil:
		s.attempt(ctx, kind, accountOf(&u), "code refused: expired, used, or tried too often")
		jsonError(w, http.StatusBadRequest, expired)
		return
	}
	s.attempt(ctx, kind, accountOf(&u), "code accepted")
	ticket, ok := s.putTicket(u.ID, req.Purpose)
	if !ok {
		busy(w)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"ticket": ticket})
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

// NoticesOnConnect tells a Mac about recoveries since it last connected (plan D5), and about
// Claude clients given access that it hasn't been told about.
func (s *Service) NoticesOnConnect(ctx context.Context, d store.Device, previous time.Time) []*agentproto.Notice {
	var out []*agentproto.Notice
	if previous.IsZero() {
		previous = d.CreatedAt
	}
	if times, err := s.cfg.Store.RecoveriesSince(ctx, d.UserID, previous); err == nil && len(times) > 0 {
		out = append(out, &agentproto.Notice{Kind: agentproto.NoticeAccountRecovered, At: times[len(times)-1].Truncate(time.Second)})
	}
	grants, err := s.cfg.Store.TakeClientAuthorizations(ctx, d.UserID, d.CreatedAt, s.now())
	if err != nil {
		s.cfg.Logger.Error("client authorizations", "err", err)
	}
	for _, g := range grants {
		out = append(out, &agentproto.Notice{Kind: agentproto.NoticeClientAuthorized, At: g.At.Truncate(time.Second), Client: g.ClientName})
	}
	return out
}

// ClientAuthorized tells the Owner's Mac that a Claude client was given access: now if it's
// online, otherwise on its next connection.
func (s *Service) ClientAuthorized(ctx context.Context, userID, clientName string) {
	now := s.now()
	told := false
	if d, err := s.cfg.Store.ActiveDevice(ctx, userID); err == nil && s.cfg.Macs.Online(d.ID) {
		n := &agentproto.Notice{Kind: agentproto.NoticeClientAuthorized, At: now.Truncate(time.Second), Client: clientName}
		told = s.cfg.Macs.SendNotice(ctx, d.ID, n) == nil
	}
	if err := s.cfg.Store.AddClientAuthorization(ctx, userID, clientName, now, told); err != nil {
		s.cfg.Logger.Error("record client authorization", "err", err)
	}
}

// attempt records a sign-in step that anyone can cause, counted per hour (FR-631): a stranger
// can't add a row per try, and an Owner's account shows how many there were. userID names the
// account only when it is a finished one (accountOf); a sign-up that was never finished is
// counted without an account, since its account is deleted after a day.
func (s *Service) attempt(ctx context.Context, kind, userID, outcome string) {
	s.cfg.Events.Count(ctx, store.Event{Kind: kind, UserID: userID, Detail: outcome})
}

// accountOf is the user's ID when the account is a finished one, else "".
func accountOf(u *store.User) string {
	if u == nil || u.EmailVerifiedAt.IsZero() {
		return ""
	}
	return u.ID
}

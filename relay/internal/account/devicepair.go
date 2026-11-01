package account

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/events"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Headless pairing (spec 010 FR-1022, plan D7), in the shape of RFC 8628's device flow: a Linux
// server asks for a code with its name, kind, and public key; the Owner enters the short code
// on /link in any signed-in browser and confirms; the server polls until it gets its device ID.

const (
	devicePairingLifetime = 10 * time.Minute
	devicePollInterval    = 5 * time.Second
	// userCodeAlphabet has no vowels (no words) and no look-alike letters (RFC 8628 §6.1).
	userCodeAlphabet = "BCDFGHJKLMNPQRSTVWXZ"
	userCodeLength   = 8
	// wrongLinkCodes per account within wrongLinkWindow refuse further codes until it passes.
	wrongLinkCodes  = 10
	wrongLinkWindow = 10 * time.Minute
)

// newUserCode is 8 letters from userCodeAlphabet, shown as ABCD-EFGH.
func newUserCode() string {
	b := make([]byte, userCodeLength)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	out := make([]byte, userCodeLength)
	for i, v := range b {
		out[i] = userCodeAlphabet[int(v)%len(userCodeAlphabet)] // 256 % 20 = 16: a slight bias, irrelevant at 10 tries per 10 minutes
	}
	return string(out[:4]) + "-" + string(out[4:])
}

// normalUserCode is a typed code in its stored form: letters only, upper case.
func normalUserCode(code string) string {
	var b strings.Builder
	for _, r := range strings.ToUpper(code) {
		if strings.ContainsRune(userCodeAlphabet, r) || (r >= 'A' && r <= 'Z') {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// linkAttempts counts wrong codes per account, in memory (a restart forgets them).
type linkAttempts struct {
	mu    sync.Mutex
	wrong map[string][]time.Time
}

func (a *linkAttempts) blocked(userID string, now time.Time) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.trim(userID, now)
	return len(a.wrong[userID]) >= wrongLinkCodes
}

func (a *linkAttempts) fail(userID string, now time.Time) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.wrong == nil {
		a.wrong = map[string][]time.Time{}
	}
	a.trim(userID, now)
	a.wrong[userID] = append(a.wrong[userID], now)
}

func (a *linkAttempts) trim(userID string, now time.Time) {
	kept := a.wrong[userID][:0]
	for _, t := range a.wrong[userID] {
		if now.Sub(t) < wrongLinkWindow {
			kept = append(kept, t)
		}
	}
	if len(kept) == 0 {
		delete(a.wrong, userID)
		return
	}
	a.wrong[userID] = kept
}

type devicePairRequest struct {
	Name      string `json:"name"`
	Kind      string `json:"kind"`
	PublicKey string `json:"public_key"` // PKIX DER, base64url without padding
}

// devicePair starts a headless pairing: POST /pair/device.
func (s *Service) devicePair(w http.ResponseWriter, r *http.Request) {
	if !requireJSON(w, r) {
		return
	}
	var req devicePairRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&req); err != nil {
		jsonError(w, http.StatusBadRequest, "Bad request.")
		return
	}
	if req.Kind != store.KindLinux {
		jsonError(w, http.StatusBadRequest, "Only Linux servers pair this way; a Mac pairs from the Latchkey app.")
		return
	}
	der, err := base64.RawURLEncoding.DecodeString(req.PublicKey)
	if err != nil || !isP256(der) {
		jsonError(w, http.StatusBadRequest, "The public key must be a P-256 key.")
		return
	}
	now := s.now()
	p := store.DevicePairing{
		Name: store.CleanDeviceName(req.Name, "Linux server"), Kind: req.Kind, PublicKey: der,
		CreatedAt: now, ExpiresAt: now.Add(devicePairingLifetime),
	}
	deviceCode := randomToken()
	var userCode string
	for range 5 { // a collision with a live code is vanishingly rare; try again
		userCode = newUserCode()
		err = s.cfg.Store.CreateDevicePairing(r.Context(), hash(deviceCode), hash(normalUserCode(userCode)), p)
		if !errors.Is(err, store.ErrConflict) {
			break
		}
	}
	if err != nil {
		jsonError(w, http.StatusInternalServerError, "Something went wrong. Try again.")
		return
	}
	// No verification_uri_complete (RFC 8628 §3.3.1): a link carrying the code would let someone
	// who started a pairing on their own machine send it to the Owner for a one-click approval.
	// The Owner types the code the machine in front of them shows (security review, 2026-10-31).
	writeJSON(w, http.StatusOK, map[string]any{
		"device_code":      deviceCode,
		"user_code":        userCode,
		"verification_uri": s.link("/link", nil),
		"interval":         int(devicePollInterval / time.Second),
		"expires_in":       int(devicePairingLifetime / time.Second),
	})
}

// devicePairToken is the server's poll: POST /pair/device/token.
func (s *Service) devicePairToken(w http.ResponseWriter, r *http.Request) {
	if !requireJSON(w, r) {
		return
	}
	var req struct {
		DeviceCode string `json:"device_code"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&req); err != nil {
		jsonError(w, http.StatusBadRequest, "Bad request.")
		return
	}
	now := s.now()
	d, last, err := s.cfg.Store.PollDevicePairing(r.Context(), hash(req.DeviceCode), now)
	switch {
	case errors.Is(err, store.ErrPairingPending):
		if !last.IsZero() && now.Sub(last) < devicePollInterval-time.Second {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "slow_down"})
			return
		}
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "authorization_pending"})
	case errors.Is(err, store.ErrPairingExpired):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "expired_token"})
	case err != nil:
		jsonError(w, http.StatusInternalServerError, "Something went wrong. Try again.")
	default:
		writeJSON(w, http.StatusOK, map[string]string{"device_id": d.ID, "name": d.Name})
	}
}

type linkView struct {
	Code      string
	Error     string
	Pairing   *store.DevicePairing
	Requested string // how long ago the machine asked, "just now", "3 minutes ago"
}

// linkPage is GET /link: the form for the code the machine shows. A code in the address is
// ignored: it must be typed (see devicePair).
func (s *Service) linkPage(w http.ResponseWriter, r *http.Request) {
	u, tok, ok := s.requireUser(w, r)
	if !ok {
		return
	}
	s.render(w, http.StatusOK, "link.html", page{Title: "Connect a machine", Email: u.Email, CSRF: s.csrfFor(tok), Data: linkView{}})
}

// lookUpLink fills the view's pairing for its code, or its error.
func (s *Service) lookUpLink(r *http.Request, userID string, v *linkView) {
	now := s.now()
	if s.links.blocked(userID, now) {
		v.Error = "Too many wrong codes. Wait a few minutes, then try again."
		return
	}
	p, err := s.cfg.Store.DevicePairingByUserCode(r.Context(), hash(normalUserCode(v.Code)), now)
	if err != nil {
		s.links.fail(userID, now)
		v.Error = "That code isn't right, or it expired. Check the code on the machine, or run Latchkey's setup there again."
		return
	}
	v.Pairing = &p
	switch ago := now.Sub(p.CreatedAt); {
	case ago < time.Minute:
		v.Requested = "just now"
	case ago < 2*time.Minute:
		v.Requested = "1 minute ago"
	default:
		v.Requested = strconv.Itoa(int(ago/time.Minute)) + " minutes ago"
	}
}

// link is POST /link: a code typed in the form (answered with the confirmation), or the
// confirmation itself (pairs the machine).
func (s *Service) linkPost(w http.ResponseWriter, r *http.Request) {
	sess, ok := s.postedUser(w, r)
	if !ok {
		return
	}
	ctx := r.Context()
	u, err := s.cfg.Store.User(ctx, sess.UserID)
	if err != nil {
		s.SignIn(w, r)
		return
	}
	tok := s.sessionToken(r)
	v := linkView{Code: r.PostFormValue("code")}
	if r.PostFormValue("confirm") == "" {
		s.lookUpLink(r, u.ID, &v)
		s.render(w, http.StatusOK, "link.html", page{Title: "Connect a machine", Email: u.Email, CSRF: s.csrfFor(tok), Data: v})
		return
	}
	if !u.SuspendedAt.IsZero() {
		s.errorPage(w, http.StatusForbidden, "This account can't connect a machine right now", "The relay's operator suspended it.")
		return
	}
	now := s.now()
	if s.links.blocked(u.ID, now) {
		s.errorPage(w, http.StatusTooManyRequests, "Too many wrong codes", "Wait a few minutes, then try again.")
		return
	}
	d, err := s.cfg.Store.ApproveDevicePairing(ctx, hash(normalUserCode(v.Code)), u.ID, now)
	if err != nil {
		s.links.fail(u.ID, now)
		s.errorPage(w, http.StatusBadRequest, "That code expired",
			"Run Latchkey's setup on the machine again, and enter the new code.")
		return
	}
	s.cfg.Events.Record(ctx, store.Event{Kind: events.MacPaired, UserID: u.ID, DeviceID: d.ID, Detail: "a Linux server"})
	s.cfg.DevicesChanged(u.ID)
	s.errorPage(w, http.StatusOK, "“"+d.Name+"” is connected",
		"Latchkey on the machine finishes setting up by itself. Claude can reach it through your Latchkey connector.")
}

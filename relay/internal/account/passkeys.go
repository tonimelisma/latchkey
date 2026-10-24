package account

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"

	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

const ceremonyLifetime = 5 * time.Minute

// Ceremony purposes.
const (
	purposeSignIn = "signin"
	purposeReauth = "reauth"
)

// ceremony is a WebAuthn exchange in progress, kept in memory between begin and finish.
type ceremony struct {
	data    webauthn.SessionData
	purpose string // verify, recover, signin, reauth
	userID  string
	ticket  string // confirmed email code, for verify and recover
	session string // session token, for reauth
	expires time.Time
}

func (s *Service) putCeremony(c *ceremony) string {
	id := randomToken()
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	for k, v := range s.ceremonies {
		if now.After(v.expires) {
			delete(s.ceremonies, k)
		}
	}
	c.expires = now.Add(ceremonyLifetime)
	s.ceremonies[id] = c
	return id
}

func (s *Service) takeCeremony(id string) (*ceremony, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, ok := s.ceremonies[id]
	delete(s.ceremonies, id)
	if !ok || s.now().After(c.expires) {
		return nil, false
	}
	return c, true
}

// waUser adapts a user and their passkeys to go-webauthn.
type waUser struct {
	user  store.User
	creds []webauthn.Credential
}

func (u *waUser) WebAuthnID() []byte                         { return []byte(u.user.ID) }
func (u *waUser) WebAuthnName() string                       { return u.user.Email }
func (u *waUser) WebAuthnDisplayName() string                { return u.user.Email }
func (u *waUser) WebAuthnCredentials() []webauthn.Credential { return u.creds }

func (s *Service) loadUser(ctx context.Context, userID string) (*waUser, error) {
	u, err := s.cfg.Store.User(ctx, userID)
	if err != nil {
		return nil, err
	}
	keys, err := s.cfg.Store.Passkeys(ctx, userID)
	if err != nil {
		return nil, err
	}
	wu := &waUser{user: u}
	for _, k := range keys {
		var c webauthn.Credential
		if err := json.Unmarshal(k.CredentialJSON, &c); err != nil {
			return nil, err
		}
		wu.creds = append(wu.creds, c)
	}
	return wu, nil
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func jsonError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// requireJSON rejects cross-site form posts: a JSON content type forces a CORS preflight. Every
// JSON endpoint here calls it first, the passkey finish steps included (they set the session).
func requireJSON(w http.ResponseWriter, r *http.Request) bool {
	if r.Header.Get("Content-Type") != "application/json" {
		jsonError(w, http.StatusUnsupportedMediaType, "Expected JSON.")
		return false
	}
	return true
}

type beginRequest struct {
	Purpose string `json:"purpose"`
	Ticket  string `json:"ticket"`
}

const ticketLifetime = 10 * time.Minute

// ticket says an emailed code was confirmed: its holder may create a passkey for the user.
type ticket struct {
	userID  string
	purpose string // verify or recover
	expires time.Time
}

func (s *Service) putTicket(userID, purpose string) string {
	id := randomToken()
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	for k, t := range s.tickets {
		if now.After(t.expires) {
			delete(s.tickets, k)
		}
	}
	s.tickets[id] = &ticket{userID: userID, purpose: purpose, expires: now.Add(ticketLifetime)}
	return id
}

// ticketFor returns a live ticket; take removes it (after the passkey is saved).
func (s *Service) ticketFor(id string, take bool) (*ticket, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.tickets[id]
	if !ok || s.now().After(t.expires) {
		return nil, false
	}
	if take {
		delete(s.tickets, id)
	}
	return t, true
}

func (s *Service) registerBegin(w http.ResponseWriter, r *http.Request) {
	if !requireJSON(w, r) {
		return
	}
	var req beginRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		jsonError(w, http.StatusBadRequest, "Bad request.")
		return
	}
	t, ok := s.ticketFor(req.Ticket, false)
	if !ok {
		jsonError(w, http.StatusBadRequest, "This took too long. Start again to get a new code.")
		return
	}
	user, err := s.loadUser(r.Context(), t.userID)
	if err != nil {
		jsonError(w, http.StatusInternalServerError, "Something went wrong. Try again.")
		return
	}
	creation, data, err := s.webauthn.BeginRegistration(user,
		webauthn.WithAuthenticatorSelection(protocol.AuthenticatorSelection{
			ResidentKey: protocol.ResidentKeyRequirementRequired, UserVerification: protocol.VerificationRequired,
		}),
		webauthn.WithResidentKeyRequirement(protocol.ResidentKeyRequirementRequired),
	)
	if err != nil {
		jsonError(w, http.StatusInternalServerError, "Something went wrong. Try again.")
		return
	}
	id := s.putCeremony(&ceremony{data: *data, purpose: t.purpose, userID: t.userID, ticket: req.Ticket})
	writeJSON(w, http.StatusOK, map[string]any{"ceremony": id, "options": creation})
}

func (s *Service) registerFinish(w http.ResponseWriter, r *http.Request) {
	if !requireJSON(w, r) { // it starts a session: no cross-site form may reach it
		return
	}
	c, ok := s.takeCeremony(r.URL.Query().Get("ceremony"))
	if !ok || (c.purpose != store.PurposeVerify && c.purpose != store.PurposeRecover) {
		jsonError(w, http.StatusBadRequest, "This took too long. Try again.")
		return
	}
	if _, ok := s.ticketFor(c.ticket, false); !ok {
		jsonError(w, http.StatusBadRequest, "This took too long. Start again to get a new code.")
		return
	}
	ctx := r.Context()
	user, err := s.loadUser(ctx, c.userID)
	if err != nil {
		jsonError(w, http.StatusBadRequest, "Start again to get a new code.")
		return
	}
	cred, err := s.webauthn.FinishRegistration(user, c.data, r)
	if err != nil {
		jsonError(w, http.StatusBadRequest, "The passkey couldn't be created. Try again.")
		return
	}
	now := s.now()
	data, err := json.Marshal(cred)
	if err == nil {
		err = s.cfg.Store.AddPasskey(ctx, c.userID, cred.ID, data, now)
	}
	if err != nil {
		jsonError(w, http.StatusInternalServerError, "The passkey couldn't be saved. Try again.")
		return
	}
	s.ticketFor(c.ticket, true)
	switch c.purpose {
	case store.PurposeVerify:
		err = s.cfg.Store.VerifyEmail(ctx, c.userID, now)
	case store.PurposeRecover:
		err = s.completeRecovery(ctx, user.user, cred.ID, now)
	}
	if err != nil {
		jsonError(w, http.StatusInternalServerError, "Something went wrong. Try again.")
		return
	}
	if err := s.startSession(w, r, c.userID); err != nil {
		jsonError(w, http.StatusInternalServerError, "Something went wrong. Try again.")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"next": safeNext(r.URL.Query().Get("next"))})
}

// completeRecovery removes old passkeys and sessions (FR-047) and announces the recovery by
// email and on the Mac (plan D5).
func (s *Service) completeRecovery(ctx context.Context, u store.User, keep []byte, now time.Time) error {
	if _, err := s.cfg.Store.DeletePasskeysExcept(ctx, u.ID, keep); err != nil {
		return err
	}
	if err := s.cfg.Store.DeleteUserSessions(ctx, u.ID); err != nil {
		return err
	}
	if err := s.cfg.Mailer.Send(ctx, u.Email, "Your Latchkey account was recovered",
		emailRecovered(now, s.link("/recover", nil), s.link("/account", nil))); err != nil {
		s.cfg.Logger.Error("recovery notice email", "err", err)
	}
	if d, err := s.cfg.Store.ActiveDevice(ctx, u.ID); err == nil && s.cfg.Macs.Online(d.ID) {
		n := &agentproto.Notice{Kind: agentproto.NoticeAccountRecovered, At: now.Truncate(time.Second)}
		if err := s.cfg.Macs.SendNotice(ctx, d.ID, n); err != nil {
			s.cfg.Logger.Warn("recovery notice to Mac", "err", err)
		}
	}
	return nil
}

func (s *Service) loginBegin(w http.ResponseWriter, r *http.Request) {
	if !requireJSON(w, r) {
		return
	}
	var req beginRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil ||
		(req.Purpose != purposeSignIn && req.Purpose != purposeReauth) {
		jsonError(w, http.StatusBadRequest, "Bad request.")
		return
	}
	c := &ceremony{purpose: req.Purpose}
	if req.Purpose == purposeReauth {
		sess, tok, ok := s.session(r)
		if !ok {
			jsonError(w, http.StatusUnauthorized, "Sign in first.")
			return
		}
		c.userID, c.session = sess.UserID, tok
	}
	assertion, data, err := s.webauthn.BeginDiscoverableLogin(webauthn.WithUserVerification(protocol.VerificationRequired))
	if err != nil {
		jsonError(w, http.StatusInternalServerError, "Something went wrong. Try again.")
		return
	}
	c.data = *data
	writeJSON(w, http.StatusOK, map[string]any{"ceremony": s.putCeremony(c), "options": assertion})
}

var errUnknownPasskey = errors.New("unknown passkey")

func (s *Service) loginFinish(w http.ResponseWriter, r *http.Request) {
	if !requireJSON(w, r) { // it starts a session: no cross-site form may reach it
		return
	}
	c, ok := s.takeCeremony(r.URL.Query().Get("ceremony"))
	if !ok || (c.purpose != purposeSignIn && c.purpose != purposeReauth) {
		jsonError(w, http.StatusBadRequest, "This took too long. Reload the page and try again.")
		return
	}
	ctx := r.Context()
	found, cred, err := s.webauthn.FinishPasskeyLogin(func(rawID, userHandle []byte) (webauthn.User, error) {
		pk, err := s.cfg.Store.PasskeyByCredentialID(ctx, rawID)
		if err != nil || pk.UserID != string(userHandle) {
			return nil, errUnknownPasskey
		}
		return s.loadUser(ctx, pk.UserID)
	}, c.data, r)
	if err != nil || cred.Authenticator.CloneWarning {
		jsonError(w, http.StatusUnauthorized, "That passkey isn't registered with this relay. If you lost your passkeys, recover your account.")
		return
	}
	u, ok := found.(*waUser)
	if !ok {
		jsonError(w, http.StatusInternalServerError, "Something went wrong. Try again.")
		return
	}
	now := s.now()
	if data, err := json.Marshal(cred); err == nil {
		_ = s.cfg.Store.UpdatePasskey(ctx, cred.ID, data, now)
	}
	if c.purpose == purposeReauth {
		if u.user.ID != c.userID {
			jsonError(w, http.StatusForbidden, "Use the passkey of the account you're signed in to.")
			return
		}
		if err := s.cfg.Store.SetSessionReauth(ctx, hash(c.session), now); err != nil {
			jsonError(w, http.StatusUnauthorized, "Sign in again.")
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"next": ""})
		return
	}
	if u.user.EmailVerifiedAt.IsZero() {
		jsonError(w, http.StatusForbidden, "Finish signing up first: open the link we emailed you.")
		return
	}
	if err := s.startSession(w, r, u.user.ID); err != nil {
		jsonError(w, http.StatusInternalServerError, "Something went wrong. Try again.")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"next": safeNext(r.URL.Query().Get("next"))})
}

package account

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/tonimelisma/latchkey/relay/internal/events"
	"github.com/tonimelisma/latchkey/relay/internal/oauth"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

type macView struct {
	Name       string
	Online     bool
	LastSeen   time.Time
	AppVersion string
	OSVersion  string
}

type clientView struct {
	ID       string // the grant's public ID, for its Remove button
	Name     string
	Redirect string
	Approved time.Time
	LastUsed time.Time
}

type accountView struct {
	Mac     *macView
	Clients []clientView
	Audit   []store.AuditEntry
	Done    string
}

func (s *Service) accountPage(w http.ResponseWriter, r *http.Request) {
	u, tok, ok := s.requireUser(w, r)
	if !ok {
		return
	}
	ctx := r.Context()
	v := accountView{Done: doneMessage(r.URL.Query().Get("done"))}
	if d, err := s.cfg.Store.ActiveDevice(ctx, u.ID); err == nil {
		mv := &macView{Name: d.Name, Online: s.cfg.Macs.Online(d.ID), AppVersion: d.AppVersion, OSVersion: d.OSVersion}
		if st, err := s.cfg.Store.DeviceState(ctx, d.ID); err == nil {
			mv.LastSeen = st.LastSeenAt
		}
		v.Mac = mv
	}
	if grants, err := s.cfg.OAuth.Grants(ctx, u.ID); err == nil {
		for _, g := range grants {
			v.Clients = append(v.Clients, clientView{
				ID: g.ID, Name: g.Label(), Redirect: g.Redirect, Approved: g.ApprovedAt, LastUsed: g.LastUsedAt,
			})
		}
	}
	v.Audit, _ = s.cfg.Store.AuditForUser(ctx, u.ID, 100)
	s.render(w, http.StatusOK, "account.html", page{Title: "Your account", Email: u.Email, CSRF: s.csrfFor(tok), Data: v, Wide: true})
}

func doneMessage(code string) string {
	switch code {
	case "mac":
		return "Your Mac was disconnected. Claude can no longer reach it."
	case "claude":
		return "Claude's access was removed. Claude will ask you to connect again next time."
	case "client":
		return "That app's access was removed. It will ask you to connect again next time."
	}
	return ""
}

// postedUser checks the session and CSRF token of a form post.
func (s *Service) postedUser(w http.ResponseWriter, r *http.Request) (store.Session, bool) {
	sess, _, ok := s.session(r)
	if !ok {
		s.SignIn(w, r)
		return store.Session{}, false
	}
	if !s.ValidCSRF(r) {
		s.errorPage(w, http.StatusForbidden, "This form expired", "Go back, reload the page, and try again.")
		return store.Session{}, false
	}
	return sess, true
}

// revokeActiveMac revokes the user's paired Mac, if any, and closes its connection (FR-052). by
// says why, for the event record.
func (s *Service) revokeActiveMac(ctx context.Context, userID, by string) error {
	d, err := s.cfg.Store.ActiveDevice(ctx, userID)
	if errors.Is(err, store.ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if err := s.cfg.Store.RevokeDevice(ctx, d.ID, s.now()); err != nil {
		return err
	}
	s.cfg.Events.Record(ctx, store.Event{Kind: events.MacUnpaired, UserID: userID, DeviceID: d.ID, Detail: by})
	s.cfg.Macs.Revoke(d.ID)
	return nil
}

func (s *Service) revokeMac(w http.ResponseWriter, r *http.Request) {
	sess, ok := s.postedUser(w, r)
	if !ok {
		return
	}
	if err := s.revokeActiveMac(r.Context(), sess.UserID, "on the account page"); err != nil {
		s.errorPage(w, http.StatusInternalServerError, "Something went wrong", "Try again.")
		return
	}
	s.cfg.DevicesChanged(sess.UserID)
	http.Redirect(w, r, "/account?done=mac", http.StatusSeeOther)
}

func (s *Service) revokeClaude(w http.ResponseWriter, r *http.Request) {
	sess, ok := s.postedUser(w, r)
	if !ok {
		return
	}
	if err := s.cfg.OAuth.RevokeUser(r.Context(), sess.UserID, "on the account page"); err != nil {
		s.errorPage(w, http.StatusInternalServerError, "Something went wrong", "Try again.")
		return
	}
	s.cfg.AccessRemoved(sess.UserID)
	http.Redirect(w, r, "/account?done=claude", http.StatusSeeOther)
}

// revokeClient removes one app's access (FR-191): the same removal the Mac app asks for with
// revoke_client. An ID that isn't one of this account's apps changes nothing.
func (s *Service) revokeClient(w http.ResponseWriter, r *http.Request) {
	sess, ok := s.postedUser(w, r)
	if !ok {
		return
	}
	if _, err := s.cfg.OAuth.RevokeGrant(r.Context(), sess.UserID, r.PostFormValue("id"), "on the account page"); err != nil {
		s.errorPage(w, http.StatusInternalServerError, "Something went wrong", "Try again.")
		return
	}
	http.Redirect(w, r, "/account?done=client", http.StatusSeeOther)
}

func (s *Service) deleteAccount(w http.ResponseWriter, r *http.Request) {
	sess, ok := s.postedUser(w, r)
	if !ok {
		return
	}
	if sess.ReauthAt.IsZero() || s.now().Sub(sess.ReauthAt) > reauthWindow {
		s.errorPage(w, http.StatusForbidden, "Confirm with your passkey",
			"For your safety, deleting the account needs your passkey again. Go back and press Delete account.")
		return
	}
	ctx := r.Context()
	if err := s.revokeActiveMac(ctx, sess.UserID, "with the account's deletion"); err != nil {
		s.errorPage(w, http.StatusInternalServerError, "Something went wrong", "Try again.")
		return
	}
	if err := s.cfg.Store.DeleteUser(ctx, sess.UserID); err != nil {
		s.errorPage(w, http.StatusInternalServerError, "Something went wrong", "Try again.")
		return
	}
	// The account's record went with it (FR-630); the relay's output keeps the line.
	s.cfg.Events.Log(store.Event{Kind: events.AccountDeleted, UserID: sess.UserID, Detail: "by its Owner, with everything the relay held about it"})
	s.cfg.DevicesChanged(sess.UserID)
	s.cfg.AccessRemoved(sess.UserID)
	s.clearSession(w)
	s.errorPage(w, http.StatusOK, "Your account was deleted",
		"Everything this relay stored about you is gone, and your Mac was disconnected. You can remove the Latchkey connector from Claude's settings.")
}

// --- pairing (plan D6) ---

const maxMacName = 100

func cleanName(n string) string {
	n = strings.TrimSpace(n)
	if n == "" || !utf8.ValidString(n) {
		return "Mac"
	}
	if utf8.RuneCountInString(n) > maxMacName {
		n = string([]rune(n)[:maxMacName])
	}
	return n
}

func (s *Service) pairPage(w http.ResponseWriter, r *http.Request) {
	u, tok, ok := s.requireUser(w, r)
	if !ok {
		return
	}
	data := map[string]string{"Name": cleanName(r.URL.Query().Get("name"))}
	if d, err := s.cfg.Store.ActiveDevice(r.Context(), u.ID); err == nil {
		data["Replaces"] = d.Name
	}
	s.render(w, http.StatusOK, "pair.html", page{Title: "Connect your Mac", Email: u.Email, CSRF: s.csrfFor(tok), Data: data})
}

func (s *Service) pair(w http.ResponseWriter, r *http.Request) {
	sess, ok := s.postedUser(w, r)
	if !ok {
		return
	}
	code := randomToken()
	if err := s.cfg.Store.CreatePairingCode(r.Context(), hash(code), sess.UserID, s.now().Add(pairingLifetime)); err != nil {
		s.errorPage(w, http.StatusInternalServerError, "Something went wrong", "Try again.")
		return
	}
	// The relay's address rides along, so the app can finish pairing even if it was restarted.
	relay := strings.TrimSuffix(s.cfg.PublicURL.String(), "/")
	w.Header().Set("Location", "latchkey://paired?"+url.Values{"code": {code}, "relay": {relay}}.Encode())
	w.WriteHeader(http.StatusSeeOther)
}

const pairingExpired = "This connection request expired. Click Connect in the Latchkey app again."

// pairPreview tells the Mac app which account a pairing code belongs to, without using the
// code, so the app can name that account when a link arrives from outside its own sign-in
// window (FR-054). The code is the secret; the answer is only the account's email.
func (s *Service) pairPreview(w http.ResponseWriter, r *http.Request) {
	if !requireJSON(w, r) {
		return
	}
	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&req); err != nil {
		jsonError(w, http.StatusBadRequest, "Bad request.")
		return
	}
	ctx := r.Context()
	userID, err := s.cfg.Store.PeekPairingCode(ctx, hash(req.Code), s.now())
	if err != nil {
		jsonError(w, http.StatusBadRequest, pairingExpired)
		return
	}
	u, err := s.cfg.Store.User(ctx, userID)
	if err != nil {
		jsonError(w, http.StatusBadRequest, pairingExpired)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"email": u.Email})
}

type exchangeRequest struct {
	Code      string `json:"code"`
	PublicKey string `json:"public_key"` // PKIX DER, base64url without padding
	Name      string `json:"name"`
}

// pairExchange is called by the Mac app with the code from the latchkey:// redirect.
func (s *Service) pairExchange(w http.ResponseWriter, r *http.Request) {
	if !requireJSON(w, r) {
		return
	}
	var req exchangeRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&req); err != nil {
		jsonError(w, http.StatusBadRequest, "Bad request.")
		return
	}
	der, err := base64.RawURLEncoding.DecodeString(req.PublicKey)
	if err != nil || !isP256(der) {
		jsonError(w, http.StatusBadRequest, "The public key must be a P-256 key.")
		return
	}
	ctx := r.Context()
	userID, err := s.cfg.Store.UsePairingCode(ctx, hash(req.Code), s.now())
	if err != nil {
		jsonError(w, http.StatusBadRequest, pairingExpired)
		return
	}
	if u, err := s.cfg.Store.User(ctx, userID); err != nil || !u.SuspendedAt.IsZero() {
		jsonError(w, http.StatusForbidden, "This account can't connect a Mac right now.")
		return
	}
	if err := s.revokeActiveMac(ctx, userID, "replaced by a newly paired Mac"); err != nil { // FR-053: the Owner confirmed on the pair page
		jsonError(w, http.StatusInternalServerError, "Something went wrong. Try again.")
		return
	}
	d, err := s.cfg.Store.CreateDevice(ctx, store.NewDevice{UserID: userID, Name: cleanName(req.Name), PublicKey: der}, s.now())
	if err != nil {
		jsonError(w, http.StatusInternalServerError, "Something went wrong. Try again.")
		return
	}
	s.cfg.Events.Record(ctx, store.Event{Kind: events.MacPaired, UserID: userID, DeviceID: d.ID})
	s.cfg.DevicesChanged(userID)
	writeJSON(w, http.StatusOK, map[string]string{"device_id": d.ID})
}

func isP256(der []byte) bool {
	pub, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return false
	}
	k, ok := pub.(*ecdsa.PublicKey)
	return ok && k.Curve == elliptic.P256()
}

// Consent implements oauth.Authenticator.
func (s *Service) Consent(w http.ResponseWriter, r *http.Request, c oauth.ConsentRequest) {
	tok := s.sessionToken(r)
	s.render(w, http.StatusOK, "consent.html", page{Title: "Allow access to your Mac", CSRF: s.csrfFor(tok), Data: c})
}

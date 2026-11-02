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

	"github.com/tonimelisma/latchkey/relay/internal/events"
	"github.com/tonimelisma/latchkey/relay/internal/oauth"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

type machineView struct {
	ID         string // the device ID, for its Remove button
	New        bool   // just connected: marked in the list (FR-656)
	Name       string
	Kind       string
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

// addClaudeView is one Add to Claude block: the button, the steps, and the way by hand.
type addClaudeView struct {
	AddLink   string // Claude's add-connector dialog with Latchkey filled in (FR-659)
	Connector string // the address to add in Claude (FR-655)
	Suffix    string // keeps the two blocks' element IDs apart
}

type accountView struct {
	Machines    []machineView
	Clients     []clientView
	Recent      []entry // the last few calls and account events (FR-651)
	MoreRecent  bool    // there are older entries on the activity page
	Done        string
	HasClaude   bool          // Claude on the web, desktop, and phone has access (FR-660)
	AddNext     addClaudeView // the next step at the top, while !HasClaude (FR-660)
	AddHere     addClaudeView // in the Claude section, always (FR-655, FR-659)
	InstallLine string        // a Linux server's install command for this relay (FR-654)
}

// installScript is where a Linux server's install command downloads the installer.
const installScript = "https://raw.githubusercontent.com/tonimelisma/latchkey/main/linux/install.sh"

func (s *Service) accountPage(w http.ResponseWriter, r *http.Request) {
	u, tok, ok := s.requireUser(w, r)
	if !ok {
		return
	}
	ctx := r.Context()
	origin := strings.TrimSuffix(s.cfg.PublicURL.String(), "/")
	connector := origin + "/mcp"
	v := accountView{
		Done:        doneMessage(r.URL.Query().Get("done")),
		InstallLine: "curl -fsSL " + installScript + " | sh -s -- " + origin,
		AddNext:     addClaudeView{AddLink: addToClaudeLink(connector), Connector: connector, Suffix: "-next"},
		AddHere:     addClaudeView{AddLink: addToClaudeLink(connector), Connector: connector},
	}
	newID := ""
	if r.URL.Query().Get("done") == "linked" {
		newID = r.URL.Query().Get("machine")
	}
	devices, _ := s.cfg.Store.ActiveDevices(ctx, u.ID)
	for _, d := range devices {
		mv := machineView{ID: d.ID, Name: d.Name, Kind: d.Kind, Online: s.cfg.Macs.Online(d.ID), AppVersion: d.AppVersion, OSVersion: d.OSVersion}
		if st, err := s.cfg.Store.DeviceState(ctx, d.ID); err == nil {
			mv.LastSeen = st.LastSeenAt
		}
		if d.ID == newID {
			mv.New = true
			v.Done = "“" + d.Name + "” is connected. It shows Online once it finishes setting up, in a few seconds."
		}
		v.Machines = append(v.Machines, mv)
	}
	if grants, err := s.cfg.OAuth.Grants(ctx, u.ID); err == nil {
		for _, g := range grants {
			v.Clients = append(v.Clients, clientView{
				ID: g.ID, Name: g.Label(), Redirect: g.Redirect, Approved: g.ApprovedAt, LastUsed: g.LastUsedAt,
			})
			v.HasClaude = v.HasClaude || hostedClaude(g.Host, g.Redirect)
		}
	}
	v.Recent, v.MoreRecent, _ = s.activity(ctx, u.ID, time.Time{}, recentEntries)
	if len(v.Recent) > recentEntries {
		v.Recent, v.MoreRecent = v.Recent[:recentEntries], true
	}
	s.render(w, http.StatusOK, "account.html", page{Title: "Your account", Email: u.Email, CSRF: s.csrfFor(tok), Data: v, Wide: true})
}

// addToClaudeLink opens Claude's Add custom connector dialog with Latchkey's name and address
// filled in: claude.ai's documented install link (plan D25). The Owner still clicks Add.
func addToClaudeLink(connector string) string {
	return "https://claude.ai/customize/connectors?modal=add-custom-connector&connectorName=Latchkey&connectorUrl=" +
		url.QueryEscape(connector)
}

// hostedClaude reports whether an approval is Claude on the web, desktop, and phone, the one that
// reaches the machines from anywhere; a program signed in on a computer, such as Claude Code, isn't.
func hostedClaude(host, redirect string) bool {
	return (host == "claude.ai" || host == "claude.com") && redirect != "this computer"
}

func doneMessage(code string) string {
	switch code {
	case "mac":
		return "Your machines were disconnected. Claude can no longer reach them."
	case "machine":
		return "The machine was removed. Claude can no longer reach it."
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

// revokeDevice revokes one of the user's machines and closes its connection (FR-052, spec 010
// FR-1011). A device that isn't the user's, or is already removed, changes nothing. by says why,
// for the event record.
func (s *Service) revokeDevice(ctx context.Context, userID, deviceID, by string) error {
	d, err := s.cfg.Store.Device(ctx, deviceID)
	if errors.Is(err, store.ErrNotFound) || (err == nil && (d.UserID != userID || d.PublicKey == nil)) {
		return nil
	}
	if err != nil {
		return err
	}
	if err := s.cfg.Store.RevokeDevice(ctx, d.ID, s.now()); err != nil && !errors.Is(err, store.ErrNotFound) {
		return err
	}
	s.cfg.Events.Record(ctx, store.Event{Kind: events.MacUnpaired, UserID: userID, DeviceID: d.ID, Detail: by})
	s.cfg.Macs.Revoke(d.ID)
	return nil
}

// revokeAllDevices revokes every machine of the user.
func (s *Service) revokeAllDevices(ctx context.Context, userID, by string) error {
	devices, err := s.cfg.Store.ActiveDevices(ctx, userID)
	if err != nil {
		return err
	}
	for _, d := range devices {
		if err := s.revokeDevice(ctx, userID, d.ID, by); err != nil {
			return err
		}
	}
	return nil
}

// revokeMac is the account page's older "Disconnect Mac" form: it removes every machine.
func (s *Service) revokeMac(w http.ResponseWriter, r *http.Request) {
	sess, ok := s.postedUser(w, r)
	if !ok {
		return
	}
	if err := s.revokeAllDevices(r.Context(), sess.UserID, "on the account page"); err != nil {
		s.errorPage(w, http.StatusInternalServerError, "Something went wrong", "Try again.")
		return
	}
	s.cfg.DevicesChanged(sess.UserID)
	http.Redirect(w, r, "/account?done=mac", http.StatusSeeOther)
}

// removeMachine removes one machine from the account page (spec 010 FR-1011).
func (s *Service) removeMachine(w http.ResponseWriter, r *http.Request) {
	sess, ok := s.postedUser(w, r)
	if !ok {
		return
	}
	if err := s.revokeDevice(r.Context(), sess.UserID, r.PostFormValue("id"), "on the account page"); err != nil {
		s.errorPage(w, http.StatusInternalServerError, "Something went wrong", "Try again.")
		return
	}
	s.cfg.DevicesChanged(sess.UserID)
	http.Redirect(w, r, "/account?done=machine", http.StatusSeeOther)
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
	if err := s.revokeAllDevices(ctx, sess.UserID, "with the account's deletion"); err != nil {
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
		"Everything this relay stored about you is gone, and your machines were disconnected. You can remove the Latchkey connector from Claude's settings.")
}

// --- pairing (plan D6) ---

func cleanName(n string) string { return store.CleanDeviceName(n, "Mac") }

// joinNames lists names as a sentence does: "a", "a and b", "a, b, and c".
func joinNames(names []string) string {
	switch len(names) {
	case 0:
		return ""
	case 1:
		return names[0]
	case 2:
		return names[0] + " and " + names[1]
	}
	return strings.Join(names[:len(names)-1], ", ") + ", and " + names[len(names)-1]
}

func (s *Service) pairPage(w http.ResponseWriter, r *http.Request) {
	u, tok, ok := s.requireUser(w, r)
	if !ok {
		return
	}
	data := map[string]string{"Name": cleanName(r.URL.Query().Get("name"))}
	if devices, err := s.cfg.Store.ActiveDevices(r.Context(), u.ID); err == nil && len(devices) > 0 {
		names := make([]string, len(devices))
		for i, d := range devices {
			names[i] = d.Name
		}
		data["Others"] = joinNames(names) // pairing adds this Mac (spec 010 FR-1012)
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
	// Replaces is the device ID this Mac was paired as before, if it has one (spec 010): that
	// pairing is removed, so pairing the same Mac again doesn't leave its old entry behind.
	Replaces string `json:"replaces,omitempty"`
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
	// Pairing adds a machine (spec 010 FR-1001); only this Mac's own earlier pairing goes, and only
	// within the account the code belongs to.
	if req.Replaces != "" {
		if err := s.revokeDevice(ctx, userID, req.Replaces, "replaced by the same Mac pairing again"); err != nil {
			jsonError(w, http.StatusInternalServerError, "Something went wrong. Try again.")
			return
		}
	}
	d, err := s.cfg.Store.CreateDevice(ctx, store.NewDevice{UserID: userID, Name: cleanName(req.Name), Kind: store.KindMac, PublicKey: der}, s.now())
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
	s.render(w, http.StatusOK, "consent.html", page{Title: "Allow access to your machines", CSRF: s.csrfFor(tok), Data: c})
}

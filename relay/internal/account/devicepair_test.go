package account_test

import (
	"context"
	"net/http"
	"net/url"
	"regexp"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

var userCodeRE = regexp.MustCompile(`^[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}$`)

// A Linux server pairs without a browser of its own: it shows a code, the Owner approves it in
// a signed-in browser, the server collects its device ID (spec 010 FR-1022, plan D7).
func TestHeadlessPairing(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.signUp()
	u, _ := e.store.UserByEmail(context.Background(), "owner@example.com")
	server := e.browser() // the server has no cookies

	status, start := server.json("/pair/device", map[string]string{"name": "homeserver", "kind": "linux", "public_key": p256DER(t)})
	require.Equal(t, http.StatusOK, status, start)
	userCode, _ := start["user_code"].(string)
	deviceCode, _ := start["device_code"].(string)
	assert.Regexp(t, userCodeRE, userCode)
	assert.NotEmpty(t, deviceCode)
	assert.Equal(t, e.base+"/link", start["verification_uri"])
	assert.Equal(t, e.base+"/link?code="+url.QueryEscape(userCode), start["verification_uri_complete"])
	assert.InDelta(t, 5, start["interval"], 0)
	assert.InDelta(t, 600, start["expires_in"], 0)

	status, poll := server.json("/pair/device/token", map[string]string{"device_code": deviceCode})
	assert.Equal(t, http.StatusBadRequest, status)
	assert.Equal(t, "authorization_pending", poll["error"])
	status, poll = server.json("/pair/device/token", map[string]string{"device_code": deviceCode})
	assert.Equal(t, http.StatusBadRequest, status)
	assert.Equal(t, "slow_down", poll["error"], "polled faster than the interval")

	// The Owner opens the link, sees the machine named, with the warning, and connects it.
	page := b.get("/link?code=" + url.QueryEscape(userCode))
	require.Equal(t, http.StatusOK, page.status)
	assert.Contains(t, page.body, "Connect “homeserver”?")
	assert.Contains(t, page.body, "Only connect a machine you just set up yourself")
	r := b.form("/link", url.Values{"csrf": {csrf(t, page.body)}, "code": {userCode}, "confirm": {"1"}})
	require.Equal(t, http.StatusOK, r.status, r.body)
	assert.Contains(t, r.body, "“homeserver” is connected")
	assert.Contains(t, e.changed, u.ID)

	e.clock.advance(6 * time.Second)
	status, poll = server.json("/pair/device/token", map[string]string{"device_code": deviceCode})
	require.Equal(t, http.StatusOK, status, poll)
	devices, err := e.store.ActiveDevices(context.Background(), u.ID)
	require.NoError(t, err)
	require.Len(t, devices, 1)
	assert.Equal(t, devices[0].ID, poll["device_id"])
	assert.Equal(t, "homeserver", poll["name"])
	assert.Equal(t, store.KindLinux, devices[0].Kind)

	e.clock.advance(6 * time.Second)
	status, poll = server.json("/pair/device/token", map[string]string{"device_code": deviceCode})
	assert.Equal(t, http.StatusBadRequest, status)
	assert.Equal(t, "expired_token", poll["error"], "collected once")

	// The approved code is used up.
	page = b.get("/link?code=" + url.QueryEscape(userCode))
	assert.Contains(t, page.body, "That code isn&#39;t right, or it expired")
}

func TestHeadlessPairingRules(t *testing.T) {
	e := setup(t)
	b := e.browser()
	server := e.browser()

	status, m := server.json("/pair/device", map[string]string{"name": "x", "kind": "mac", "public_key": p256DER(t)})
	assert.Equal(t, http.StatusBadRequest, status, "a Mac pairs from the app")
	assert.Contains(t, m["error"], "Mac pairs from the Latchkey app")
	status, _ = server.json("/pair/device", map[string]string{"name": "x", "kind": "linux", "public_key": "not-a-key"})
	assert.Equal(t, http.StatusBadRequest, status)
	r := server.do(http.MethodPost, "/pair/device", "text/plain", nil)
	assert.Equal(t, http.StatusUnsupportedMediaType, r.status)

	assert.Equal(t, http.StatusFound, b.get("/link").status, "sign in first")
	b.signUp()

	// Typing the code with dashes, spaces, or lower case works.
	_, start := server.json("/pair/device", map[string]string{"name": "pi", "kind": "linux", "public_key": p256DER(t)})
	code, _ := start["user_code"].(string)
	page := b.get("/link")
	r = b.form("/link", url.Values{"csrf": {csrf(t, page.body)}, "code": {" " + code[:4] + " " + code[5:] + " "}})
	assert.Contains(t, r.body, "Connect “pi”?")

	// Wrong codes: 10 per account, then the form refuses for 10 minutes.
	for range 10 {
		r = b.form("/link", url.Values{"csrf": {csrf(t, page.body)}, "code": {"BBBB-BBBB"}})
		assert.Contains(t, r.body, "That code isn&#39;t right")
	}
	r = b.form("/link", url.Values{"csrf": {csrf(t, page.body)}, "code": {code}})
	assert.Contains(t, r.body, "Too many wrong codes")
	e.clock.advance(11 * time.Minute)
	// By then the request itself has expired too.
	r = b.form("/link", url.Values{"csrf": {csrf(t, page.body)}, "code": {code}})
	assert.Contains(t, r.body, "That code isn&#39;t right, or it expired")
	r = b.form("/link", url.Values{"csrf": {csrf(t, page.body)}, "code": {code}, "confirm": {"1"}})
	assert.Equal(t, http.StatusBadRequest, r.status)

	r = b.form("/link", url.Values{"csrf": {"forged"}, "code": {code}})
	assert.Equal(t, http.StatusForbidden, r.status)
}

// The account page lists every machine and removes one at a time (spec 010 FR-1011).
func TestAccountPageRemovesOneMachine(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.signUp()
	ctx := context.Background()
	u, _ := e.store.UserByEmail(ctx, "owner@example.com")
	mac, err := e.store.CreateDevice(ctx, store.NewDevice{UserID: u.ID, Name: "Toni's MacBook", PublicKey: []byte("k")}, e.clock.now())
	require.NoError(t, err)
	server, err := e.store.CreateDevice(ctx, store.NewDevice{UserID: u.ID, Name: "homeserver", Kind: store.KindLinux, PublicKey: []byte("k")}, e.clock.now())
	require.NoError(t, err)
	other, err := e.store.CreateUser(ctx, "other@example.com", e.clock.now())
	require.NoError(t, err)
	theirs, err := e.store.CreateDevice(ctx, store.NewDevice{UserID: other.ID, Name: "Theirs", PublicKey: []byte("k")}, e.clock.now())
	require.NoError(t, err)

	page := b.get("/account")
	assert.Contains(t, page.body, "Toni&#39;s MacBook")
	assert.Contains(t, page.body, "homeserver")
	assert.Contains(t, page.body, "Linux server")
	assert.NotContains(t, page.body, "Theirs")
	token := csrf(t, page.body)

	r := b.form("/account/machines/remove", url.Values{"csrf": {token}, "id": {server.ID}})
	assert.Equal(t, http.StatusSeeOther, r.status)
	assert.Equal(t, []string{server.ID}, e.macs.revoked)
	left, err := e.store.ActiveDevices(ctx, u.ID)
	require.NoError(t, err)
	require.Len(t, left, 1)
	assert.Equal(t, mac.ID, left[0].ID, "the other machine stays")
	assert.Contains(t, b.get("/account?done=machine").body, "The machine was removed")

	r = b.form("/account/machines/remove", url.Values{"csrf": {token}, "id": {theirs.ID}})
	assert.Equal(t, http.StatusSeeOther, r.status)
	assert.NotContains(t, e.macs.revoked, theirs.ID, "another account's machine is untouched")
	r = b.form("/account/machines/remove", url.Values{"csrf": {"forged"}, "id": {mac.ID}})
	assert.Equal(t, http.StatusForbidden, r.status)
}

package account_test

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/account"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// The security emails (FR-696 to FR-699): a new machine, a newly allowed app, and a completed
// recovery each reach the Owner's inbox at once, so a stolen account or a rogue connector shows.

// newMail is what was sent to the owner since before (a count of e.mail.Sent()), once every
// email in progress has been handed to the mailer.
func (e *env) newMail(before int) []account.Message {
	e.t.Helper()
	e.svc.WaitForMail()
	var out []account.Message
	for _, m := range e.mail.Sent()[before:] {
		if m.To == owner {
			out = append(out, m)
		}
	}
	return out
}

// postInBackground posts v as JSON from another goroutine, without asserting there, and sends
// the answer's status (0 if the request failed).
func (b *browser) postInBackground(path string, v any) <-chan int {
	data, _ := json.Marshal(v)
	status := make(chan int, 1)
	go func() {
		req, err := http.NewRequestWithContext(context.Background(), http.MethodPost, b.e.base+path, strings.NewReader(string(data)))
		if err != nil {
			status <- 0
			return
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := b.http.Do(req)
		if err != nil {
			status <- 0
			return
		}
		_ = resp.Body.Close()
		status <- resp.StatusCode
	}()
	return status
}

// assertSecurityEmail checks what every security email says (FR-699).
func (e *env) assertSecurityEmail(m account.Message, secrets ...string) {
	e.t.Helper()
	assert.Contains(e.t, m.Body, e.clock.now().UTC().Format("Jan 2, 2006 at 3:04 PM")+" UTC", "when, in UTC")
	assert.Contains(e.t, m.Body, "The request came from the IP address 127.0.0.1.", "from where")
	assert.Contains(e.t, m.Body, "If it wasn't you,", "what to do")
	assert.Contains(e.t, m.Body, e.base+"/account", "the account page, where it can be removed")
	assert.Contains(e.t, m.Body, e.base+"/recover")
	assert.NotRegexp(e.t, `\b\d{6}\b`, m.Body, "no code")
	for _, s := range secrets {
		assert.NotContains(e.t, m.Body, s, "no secret")
	}
}

func TestPairingAMacIsEmailed(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.signUp()
	mac := e.browser()

	before := len(e.mail.Sent())
	code := b.pairCode("Toni's MacBook")
	status, m := mac.json("/pair/exchange", map[string]string{"code": code, "public_key": p256DER(t), "name": "Toni's MacBook"})
	require.Equal(t, http.StatusOK, status, m)
	sent := e.newMail(before)
	require.Len(t, sent, 1, "one email for the new Mac")
	assert.Equal(t, "A Mac was connected to your Latchkey account", sent[0].Subject)
	assert.Contains(t, sent[0].Body, "A Mac named “Toni's MacBook” was connected to your Latchkey account on ")
	e.assertSecurityEmail(sent[0], code)

	// The same Mac pairing again is a new credential too: emailed as well.
	before = len(e.mail.Sent())
	code = b.pairCode("Toni's MacBook")
	status, _ = mac.json("/pair/exchange", map[string]string{"code": code, "public_key": p256DER(t), "name": "Toni's MacBook", "replaces": m["device_id"].(string)})
	require.Equal(t, http.StatusOK, status)
	assert.Len(t, e.newMail(before), 1)

	// A code that doesn't pair sends nothing.
	before = len(e.mail.Sent())
	status, _ = mac.json("/pair/exchange", map[string]string{"code": code, "public_key": p256DER(t), "name": "Again"})
	require.Equal(t, http.StatusBadRequest, status)
	assert.Empty(t, e.newMail(before))
}

func TestPairingALinuxServerIsEmailed(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.signUp()
	server := e.browser()
	status, start := server.json("/pair/device", map[string]string{"name": "homeserver", "kind": "linux", "public_key": p256DER(t)})
	require.Equal(t, http.StatusOK, status, start)
	userCode := start["user_code"].(string)

	before := len(e.mail.Sent())
	page := b.get("/link")
	r := b.form("/link", url.Values{"csrf": {csrf(t, page.body)}, "code": {userCode}})
	require.Equal(t, http.StatusOK, r.status)
	assert.Empty(t, e.newMail(before), "looking the code up connects nothing")
	r = b.form("/link", url.Values{"csrf": {csrf(t, r.body)}, "code": {userCode}, "confirm": {"1"}})
	require.Equal(t, http.StatusSeeOther, r.status, r.body)
	sent := e.newMail(before)
	require.Len(t, sent, 1)
	assert.Equal(t, "A Linux server was connected to your Latchkey account", sent[0].Subject)
	assert.Contains(t, sent[0].Body, "A Linux server named “homeserver” was connected to your Latchkey account on ")
	e.assertSecurityEmail(sent[0], userCode, start["device_code"].(string))
}

// authorizeQuery is an authorization request of a registered client; the verifier is RFC
// 7636's example.
func authorizeQuery(clientID, redirect string) url.Values {
	return url.Values{
		"response_type": {"code"}, "client_id": {clientID}, "redirect_uri": {redirect},
		"scope": {"mcp offline_access"}, "state": {"abcdefghijk"}, "code_challenge": {"E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"}, "code_challenge_method": {"S256"},
	}
}

func TestAllowingAnAppIsEmailed(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.signUp()
	const redirect = "https://claude.ai/api/mcp/auth_callback"
	status, reg := b.json("/register", map[string]any{"client_name": "Claude", "redirect_uris": []string{redirect}, "token_endpoint_auth_method": "none"})
	require.Equal(t, http.StatusCreated, status)
	clientID := reg["client_id"].(string)
	q := authorizeQuery(clientID, redirect)

	// Don't Allow sends nothing.
	before := len(e.mail.Sent())
	page := b.get("/authorize?" + q.Encode())
	r := b.form("/authorize?"+q.Encode(), url.Values{"csrf": {csrf(t, page.body)}, "decision": {"deny"}})
	require.Contains(t, r.header.Get("Location"), "error=access_denied")
	assert.Empty(t, e.newMail(before))

	page = b.get("/authorize?" + q.Encode())
	r = b.form("/authorize?"+q.Encode(), url.Values{"csrf": {csrf(t, page.body)}, "decision": {"allow"}})
	loc, err := url.Parse(r.header.Get("Location"))
	require.NoError(t, err)
	code := loc.Query().Get("code")
	require.NotEmpty(t, code, r.header.Get("Location"))
	sent := e.newMail(before)
	require.Len(t, sent, 1)
	assert.Equal(t, "An app was allowed to use your Latchkey machines", sent[0].Subject)
	assert.Contains(t, sent[0].Body, "The app “Claude (claude.ai)” was allowed to use your machines on ", "named as on the consent page")
	assert.Contains(t, sent[0].Body, "The approval was sent back to claude.ai.")
	e.assertSecurityEmail(sent[0], code)

	// Redeeming the code and refreshing the access are no new approval (FR-697).
	before = len(e.mail.Sent())
	tok := b.form("/token", url.Values{
		"grant_type": {"authorization_code"}, "code": {code}, "client_id": {clientID},
		"redirect_uri": {redirect}, "code_verifier": {"dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"},
	})
	require.Equal(t, http.StatusOK, tok.status, tok.body)
	var tokens map[string]any
	require.NoError(t, json.Unmarshal([]byte(tok.body), &tokens))
	refreshed := b.form("/token", url.Values{"grant_type": {"refresh_token"}, "refresh_token": {tokens["refresh_token"].(string)}, "client_id": {clientID}})
	require.Equal(t, http.StatusOK, refreshed.status, refreshed.body)
	assert.Empty(t, e.newMail(before))
}

func TestCompletedRecoveryIsEmailed(t *testing.T) {
	e := setup(t)
	e.browser().signUp()
	e.clock.advance(2 * time.Minute)
	lost := e.browser()
	status, r := lost.startEmail(owner, true)
	require.Equal(t, http.StatusOK, status, r)
	code := e.lastCode()
	status, ticket := lost.confirmCode(code, store.PurposeRecover)
	require.Equal(t, http.StatusOK, status, ticket)

	// The recovery completes at once though the mail server is slow (FR-699).
	status, begin := lost.json("/passkey/register/begin", map[string]string{"ticket": ticket["ticket"].(string)})
	require.Equal(t, http.StatusOK, status, begin)
	cred := lost.authn.create(t, begin["options"].(map[string]any), e.base)
	before := len(e.mail.Sent())
	release := e.mailer.hold()
	defer release()
	done := lost.postInBackground("/passkey/register/finish?ceremony="+begin["ceremony"].(string)+"&next=/account", cred)
	select {
	case status := <-done:
		require.Equal(t, http.StatusOK, status)
	case <-time.After(2 * time.Second):
		t.Fatal("the recovery waited for the mail server")
	}
	release()
	sent := e.newMail(before)
	require.Len(t, sent, 1)
	assert.Equal(t, "Your Latchkey account was recovered", sent[0].Subject)
	assert.Contains(t, sent[0].Body, "Your Latchkey account was recovered on ")
	e.assertSecurityEmail(sent[0], code)
}

// A pairing answers at once while the mail server hangs, and works when it fails; the failure is
// logged (FR-699).
func TestSecurityEmailsNeverHoldUpOrFailTheChange(t *testing.T) {
	out := &logBuffer{}
	e := setupWith(t, func(c *account.Config) { c.Logger = slog.New(slog.NewTextHandler(out, nil)) })
	b := e.browser()
	b.signUp()
	mac := e.browser()

	release := e.mailer.hold()
	defer release()
	before := len(e.mail.Sent())
	code := b.pairCode("Slow")
	answered := mac.postInBackground("/pair/exchange", map[string]string{"code": code, "public_key": p256DER(t), "name": "Slow"})
	select {
	case status := <-answered:
		require.Equal(t, http.StatusOK, status)
	case <-time.After(2 * time.Second):
		t.Fatal("pairing waited for the mail server")
	}
	assert.Len(t, e.mail.Sent(), before, "not sent yet")
	release()
	assert.Len(t, e.newMail(before), 1)

	e.mailer.fail(errors.New("mail server down"))
	code = b.pairCode("Unlucky")
	status, m := mac.json("/pair/exchange", map[string]string{"code": code, "public_key": p256DER(t), "name": "Unlucky"})
	require.Equal(t, http.StatusOK, status, m)
	e.svc.WaitForMail()
	assert.Contains(t, out.String(), "security email not sent")
	assert.Contains(t, out.String(), "mail server down")
	devices, err := e.store.ActiveDevices(context.Background(), e.ownerID())
	require.NoError(t, err)
	assert.Len(t, devices, 2, "the Mac is connected all the same")
}

func (e *env) ownerID() string {
	e.t.Helper()
	u, err := e.store.UserByEmail(context.Background(), owner)
	require.NoError(e.t, err)
	return u.ID
}

// Other accounts can't use up the relay-wide allowance and so silence an Owner's security
// email: each account's first 3 in 6 hours go out whatever the relay-wide limit says, and a send
// the relay-wide limit refuses costs the account none of its own allowance (FR-699; security
// review, 2026-11-21).
func TestOtherAccountsCantSilenceAnOwnersSecurityEmail(t *testing.T) {
	out := &logBuffer{}
	e := setupWith(t, func(c *account.Config) { c.Logger = slog.New(slog.NewTextHandler(out, nil)) })
	b := e.browser()
	b.signUp()
	ctx := context.Background()

	// An attacker's own accounts send security emails until the relay-wide allowance is gone.
	for i := range 20 {
		attacker, err := e.store.CreateUser(ctx, "attacker"+strconv.Itoa(i)+"@example.com", e.clock.now())
		require.NoError(t, err)
		require.NoError(t, e.store.VerifyEmail(ctx, attacker.ID, e.clock.now()))
		for range 10 {
			e.svc.ClientAuthorized(ctx, attacker.ID, "Claude (claude.ai)", "claude.ai")
		}
	}
	e.svc.WaitForMail()
	require.Contains(t, out.String(), "level=ERROR msg=\"security email not sent: relay-wide limit reached\"",
		"the relay-wide limit was reached, and said so at Error level for the operator")

	// The Owner's account is taken over: a Mac is paired. The email still goes out.
	before := len(e.mail.Sent())
	code := b.pairCode("Intruder")
	status, m := e.browser().json("/pair/exchange", map[string]string{"code": code, "public_key": p256DER(t), "name": "Intruder"})
	require.Equal(t, http.StatusOK, status, m)
	sent := e.newMail(before)
	require.Len(t, sent, 1, "the Owner hears of it")
	assert.Contains(t, sent[0].Body, "“Intruder”")

	// Two more go out from the reserve; after that, sends the relay-wide limit refuses don't
	// use up the account's own allowance of 10.
	id := e.ownerID()
	before = len(e.mail.Sent())
	for range 7 {
		e.svc.ClientAuthorized(ctx, id, "Claude (claude.ai)", "claude.ai")
	}
	assert.Len(t, e.newMail(before), 2, "the reserve's other two")
	e.clock.advance(4 * time.Minute) // the relay-wide allowance refills 8; the account's, none
	before = len(e.mail.Sent())
	for range 9 {
		e.svc.ClientAuthorized(ctx, id, "Claude (claude.ai)", "claude.ai")
	}
	assert.Len(t, e.newMail(before), 7, "the account's own allowance of 10 is all there: 3 used, 7 left")
}

// accounts makes n confirmed accounts and returns their IDs.
func (e *env) accounts(prefix string, n int) []string {
	e.t.Helper()
	ctx := context.Background()
	ids := make([]string, n)
	for i := range n {
		u, err := e.store.CreateUser(ctx, prefix+strconv.Itoa(i)+"@example.com", e.clock.now())
		require.NoError(e.t, err)
		require.NoError(e.t, e.store.VerifyEmail(ctx, u.ID, e.clock.now()))
		ids[i] = u.ID
	}
	return ids
}

// spendReserves sends each account's 3 reserve-covered emails, so its next ones aren't.
func (e *env) spendReserves(ids []string) {
	e.t.Helper()
	for _, id := range ids {
		for range 3 {
			e.svc.ClientAuthorized(context.Background(), id, "Claude (claude.ai)", "claude.ai")
		}
	}
	e.svc.WaitForMail()
}

// Reserve-covered emails have a relay-wide ceiling of their own, 300 at once, so many accounts'
// reserves together stay bounded; past it they fall back to the ordinary relay-wide allowance,
// and past that nothing goes (FR-699a).
func TestReservedEmailsHaveARelayWideCeiling(t *testing.T) {
	out := &logBuffer{}
	e := setupWith(t, func(c *account.Config) { c.Logger = slog.New(slog.NewTextHandler(out, nil)) })
	ids := e.accounts("user", 140)
	before := len(e.mail.Sent())
	e.spendReserves(ids) // 420 reserve-covered emails
	assert.Len(t, e.mail.Sent()[before:], 400, "300 reserved, then the ordinary 100")
	assert.Contains(t, out.String(), "level=ERROR msg=\"security email not sent: relay-wide limit for reserved emails reached\"")
}

// 4 of the 16 sending slots are kept for reserve-covered emails: other accounts' ordinary ones
// can't hold them all while the mail server is slow (FR-699a).
func TestSlotsAreKeptForReserveCoveredEmails(t *testing.T) {
	out := &logBuffer{}
	e := setupWith(t, func(c *account.Config) { c.Logger = slog.New(slog.NewTextHandler(out, nil)) })
	account.SetAlertTimes(t, 300*time.Millisecond, 5*time.Second)
	e.browser().signUp()
	attackers := e.accounts("attacker", 3)
	e.spendReserves(attackers)

	release := e.mailer.hold()
	defer release()
	before := len(e.mail.Sent())
	ctx := context.Background()
	for _, id := range attackers {
		for range 7 { // 21 ordinary emails for 12 ordinary slots
			e.svc.ClientAuthorized(ctx, id, "Claude (claude.ai)", "claude.ai")
		}
	}
	e.svc.ClientAuthorized(ctx, e.ownerID(), "Intruder (evil.example)", "evil.example")
	time.Sleep(600 * time.Millisecond) // past the wait: whatever had no slot gave up
	release()
	e.svc.WaitForMail()
	assert.Contains(t, out.String(), "security email not sent: no sending slot in time", "the ordinary ones beyond 12 waited in vain")
	var toOwner []account.Message
	for _, m := range e.mail.Sent()[before:] {
		if m.To == owner {
			toOwner = append(toOwner, m)
		}
	}
	require.Len(t, toOwner, 1, "the Owner's email had a slot of its own")
	assert.Contains(t, toOwner[0].Body, "Intruder (evil.example)")
	assert.Len(t, e.mail.Sent()[before:], 13, "12 ordinary ones and the Owner's")
}

// Waiting for a slot and sending have deadlines of their own: an email that waited still gets its
// whole send time once it holds a slot (FR-699a).
func TestTheSendDeadlineStartsOnceASlotIsHeld(t *testing.T) {
	e := setup(t)
	account.SetAlertTimes(t, 2*time.Second, time.Second)
	attackers := e.accounts("user", 2)
	e.spendReserves(attackers)

	release := e.mailer.hold()
	defer release()
	before := len(e.mail.Sent())
	ctx := context.Background()
	for i := range 13 { // 12 take the ordinary slots; one waits
		e.svc.ClientAuthorized(ctx, attackers[i%2], "Claude (claude.ai)", "claude.ai")
	}
	// The 12 sends give up after 1 s; the waiting one takes a slot then, with a second of its
	// own, and the mail server answers half way through it.
	time.Sleep(1500 * time.Millisecond)
	release()
	e.svc.WaitForMail()
	assert.Len(t, e.mail.Sent()[before:], 1, "the one that waited was sent")
}

// At most so many emails of each kind wait for a slot; one more is dropped and logged at Error
// (FR-699a).
func TestWaitingEmailsAreCapped(t *testing.T) {
	out := &logBuffer{}
	e := setupWith(t, func(c *account.Config) { c.Logger = slog.New(slog.NewTextHandler(out, nil)) })
	account.SetAlertWaiters(t, 2)
	attackers := e.accounts("user", 3)
	e.spendReserves(attackers)

	release := e.mailer.hold()
	defer release()
	before := len(e.mail.Sent())
	ctx := context.Background()
	for _, id := range attackers {
		for range 5 { // 15: 12 slots, 2 waiting, 1 too many
			e.svc.ClientAuthorized(ctx, id, "Claude (claude.ai)", "claude.ai")
		}
	}
	assert.Contains(t, out.String(), "level=ERROR msg=\"security email not sent: too many waiting to be sent\"")
	release()
	e.svc.WaitForMail()
	assert.Len(t, e.mail.Sent()[before:], 14)
}

// While the mail server is slow, every sending slot can be busy with other accounts' emails; the
// Owner's waits for a free one instead of being dropped (FR-699).
func TestBusySendingSlotsDontDropAnEmail(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	release := e.mailer.hold()
	defer release()
	for i := range 20 { // more than the 16 slots
		u, err := e.store.CreateUser(ctx, "user"+strconv.Itoa(i)+"@example.com", e.clock.now())
		require.NoError(t, err)
		require.NoError(t, e.store.VerifyEmail(ctx, u.ID, e.clock.now()))
		e.svc.ClientAuthorized(ctx, u.ID, "Claude (claude.ai)", "claude.ai")
	}
	release()
	e.svc.WaitForMail()
	assert.Len(t, e.mail.Sent(), 20, "every one sent")
}

// At most 10 security emails per account at once, then one every 6 minutes; another account
// has its own allowance (FR-699).
func TestSecurityEmailsAreCappedPerAccount(t *testing.T) {
	out := &logBuffer{}
	e := setupWith(t, func(c *account.Config) { c.Logger = slog.New(slog.NewTextHandler(out, nil)) })
	e.browser().signUp()
	ctx := context.Background()
	id := e.ownerID()
	before := len(e.mail.Sent())
	for range 15 {
		e.svc.ClientAuthorized(ctx, id, "Claude (claude.ai)", "claude.ai")
	}
	sent := e.newMail(before)
	assert.Len(t, sent, 10)
	assert.Contains(t, out.String(), "security email not sent: too many for the account")
	assert.NotContains(t, sent[0].Body, "IP address", "no address known: none named")

	e.clock.advance(6 * time.Minute)
	before = len(e.mail.Sent())
	e.svc.ClientAuthorized(ctx, id, "Claude (claude.ai)", "claude.ai")
	e.svc.ClientAuthorized(ctx, id, "Claude (claude.ai)", "claude.ai")
	assert.Len(t, e.newMail(before), 1, "one more after 6 minutes")

	other, err := e.store.CreateUser(ctx, "other@example.com", e.clock.now())
	require.NoError(t, err)
	require.NoError(t, e.store.VerifyEmail(ctx, other.ID, e.clock.now()))
	before = len(e.mail.Sent())
	e.svc.ClientAuthorized(ctx, other.ID, "Claude (claude.ai)", "claude.ai")
	e.svc.WaitForMail()
	got := e.mail.Sent()[before:]
	require.Len(t, got, 1, "another account isn't held back")
	assert.Equal(t, "other@example.com", got[0].To)
	assert.True(t, strings.HasPrefix(got[0].Subject, "An app was allowed"))
}

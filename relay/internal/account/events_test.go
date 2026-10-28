package account_test

import (
	"bytes"
	"context"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/account"
	"github.com/tonimelisma/latchkey/relay/internal/events"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

type logBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *logBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *logBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

// setupEvents is setup with an event recorder on the store, logging to the returned buffer.
func setupEvents(t *testing.T) (*env, *logBuffer) {
	t.Helper()
	out := &logBuffer{}
	var rec *events.Recorder
	e := setupWith(t, func(c *account.Config) {
		rec = events.New(c.Store, slog.New(slog.NewTextHandler(out, nil)), nil)
		c.Events = rec
	})
	return e, out
}

// has reports whether the account (or, with userID "", no account) has an event of the kind
// whose detail contains detail.
func (e *env) has(userID, kind, detail string) bool {
	e.t.Helper()
	all, err := e.store.Events(context.Background(), userID, 1000)
	require.NoError(e.t, err)
	for _, ev := range all {
		if ev.Kind == kind && strings.Contains(ev.Detail, detail) {
			return true
		}
	}
	return false
}

// FR-631, FR-636: each sign-in attempt and its outcome, by passkey, emailed code, and recovery.
func TestSignInEventsAreRecorded(t *testing.T) {
	e, out := setupEvents(t)
	b := e.browser()

	// Sign-up by emailed code: the steps before the account exists are counted without one.
	b.signUp()
	u, err := e.store.UserByEmail(context.Background(), owner)
	require.NoError(t, err)
	assert.True(t, e.has("", events.SignInCode, "sign-up code emailed"))
	assert.True(t, e.has("", events.SignInCode, "code accepted"))
	assert.True(t, e.has(u.ID, events.SignInCode, "signed up"))
	assert.Contains(t, out.String(), `msg="emailed code sign-in"`)

	// Passkey: signed in, and refused.
	status, _ := b.signIn("signin", nil)
	require.Equal(t, http.StatusOK, status)
	assert.True(t, e.has(u.ID, events.SignInPasskey, "signed in"))
	stranger := e.browser()
	stranger.authn.creds["y"] = &softCred{id: []byte("unknown-credential"), key: mustKey(t), userHandle: []byte("usr_x"), rpID: "localhost"}
	status, _ = stranger.signIn("signin", stranger.authn.creds["y"])
	require.Equal(t, http.StatusUnauthorized, status)
	assert.True(t, e.has("", events.SignInPasskey, "refused: passkey not registered"))
	assert.Contains(t, out.String(), `msg="passkey sign-in"`)

	// A wrong emailed code for the account.
	lost := e.browser()
	e.clock.advance(2 * time.Minute)
	status, _ = lost.startEmail(owner, true)
	require.Equal(t, http.StatusOK, status)
	e.svc.WaitForMail()
	status, _ = lost.confirmCode("00000000", store.PurposeRecover)
	require.Equal(t, http.StatusBadRequest, status)
	assert.True(t, e.has(u.ID, events.Recovery, "recovery code requested"))
	assert.True(t, e.has(u.ID, events.Recovery, "code refused: wrong code"))

	// The recovery itself.
	e.clock.advance(2 * time.Minute)
	lost.codeFlow(store.PurposeRecover)
	assert.True(t, e.has(u.ID, events.Recovery, "account recovered"))
	assert.Contains(t, out.String(), `msg="account recovery"`)

	// Nothing secret is in the record or the output: no code, no address.
	all, err := e.store.Events(context.Background(), u.ID, 1000)
	require.NoError(t, err)
	strangers, err := e.store.Events(context.Background(), "", 1000)
	require.NoError(t, err)
	var codes []string
	for _, m := range e.mail.Sent() {
		if c := codeRE.FindStringSubmatch(m.Body); c != nil {
			codes = append(codes, c[1])
		}
	}
	require.NotEmpty(t, codes)
	for _, ev := range append(all, strangers...) {
		assert.NotContains(t, ev.Detail, owner)
		for _, c := range codes {
			assert.NotContains(t, ev.Detail, c)
		}
	}
	assert.NotContains(t, out.String(), owner)
	for _, c := range codes {
		assert.NotContains(t, out.String(), c)
	}
}

// FR-631, FR-636: pairing and unpairing.
func TestPairingEventsAreRecorded(t *testing.T) {
	e, out := setupEvents(t)
	b := e.browser()
	b.signUp()
	u, err := e.store.UserByEmail(context.Background(), owner)
	require.NoError(t, err)

	mac := e.browser()
	status, m := mac.json("/pair/exchange", map[string]string{"code": b.pairCode("Mac"), "public_key": p256DER(t), "name": "Mac"})
	require.Equal(t, http.StatusOK, status, m)
	assert.True(t, e.has(u.ID, events.MacPaired, ""))
	assert.Contains(t, out.String(), `msg="Mac paired"`)

	status, _ = mac.json("/pair/exchange", map[string]string{"code": b.pairCode("New Mac"), "public_key": p256DER(t), "name": "New Mac"})
	require.Equal(t, http.StatusOK, status)
	assert.True(t, e.has(u.ID, events.MacUnpaired, "replaced by a newly paired Mac"))

	page := b.get("/account")
	r := b.form("/account/revoke-mac", url.Values{"csrf": {csrf(t, page.body)}})
	require.Equal(t, http.StatusSeeOther, r.status)
	assert.True(t, e.has(u.ID, events.MacUnpaired, "on the account page"))
	assert.Contains(t, out.String(), `msg="Mac unpaired"`)
}

package account_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/account"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

const suspendedText = "This account has been suspended by the person who runs this relay."

// A suspended account is signed out everywhere, and sign-in, recovery, and a passkey that
// still verifies are all refused in plain words that name the operator's contact address; when
// the suspension is lifted, sign-in works again (FR-196).
func TestSuspendedAccountCannotSignIn(t *testing.T) {
	e := setupWith(t, func(c *account.Config) { c.Operator = operator })
	b := e.browser()
	b.signUp()
	require.Equal(t, http.StatusOK, b.get("/account").status)
	ctx := context.Background()
	_, changed, err := e.store.SuspendUser(ctx, owner, "abuse", "root", e.clock.now())
	require.NoError(t, err)
	require.True(t, changed)
	want := suspendedText + " To ask about it, write to relay-owner@example.org."

	assert.Equal(t, http.StatusFound, b.get("/account").status, "every browser sign-in ended at once")
	assert.Equal(t, http.StatusFound, b.get("/pair?name=Mac").status)

	status, r := b.startEmail(owner, false)
	assert.Equal(t, http.StatusForbidden, status, "sign-in")
	assert.Equal(t, want, r["error"])
	sent := len(e.mail.Sent())
	status, r = b.startEmail(owner, true)
	assert.Equal(t, http.StatusForbidden, status, "recovery")
	assert.Equal(t, want, r["error"])
	assert.Len(t, e.mail.Sent(), sent, "no recovery code is emailed")

	status, r = b.signIn("signin", nil)
	assert.Equal(t, http.StatusForbidden, status, "the passkey itself (as browser autofill uses it)")
	assert.Equal(t, want, r["error"])
	assert.Equal(t, http.StatusFound, b.get("/account").status, "and no session was started")

	_, changed, err = e.store.UnsuspendUser(ctx, owner, "root", e.clock.now())
	require.NoError(t, err)
	require.True(t, changed)
	status, r = b.startEmail(owner, false)
	require.Equal(t, http.StatusOK, status)
	assert.Equal(t, "passkey", r["step"])
	status, _ = b.signIn("signin", nil)
	require.Equal(t, http.StatusOK, status, "sign-in is restored")
	assert.Equal(t, http.StatusOK, b.get("/account").status)
}

// Without a contact address the message is the plain sentence alone.
func TestSuspendedMessageWithoutAContact(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.signUp()
	_, _, err := e.store.SuspendUser(context.Background(), owner, "", "root", e.clock.now())
	require.NoError(t, err)
	status, r := b.startEmail(owner, false)
	assert.Equal(t, http.StatusForbidden, status)
	assert.Equal(t, suspendedText, r["error"])
}

// A suspension between the emailed code and the passkey stops the sign-up or recovery there.
func TestSuspensionStopsARecoveryInProgress(t *testing.T) {
	e := setup(t)
	e.browser().signUp()
	lost := e.browser()
	e.clock.advance(2 * time.Minute)
	status, r := lost.startEmail(owner, true)
	require.Equal(t, http.StatusOK, status, r)
	status, ticket := lost.confirmCode(e.lastCode(), store.PurposeRecover)
	require.Equal(t, http.StatusOK, status, ticket)
	status, begin := lost.json("/passkey/register/begin", map[string]string{"ticket": ticket["ticket"].(string)})
	require.Equal(t, http.StatusOK, status, begin)

	_, _, err := e.store.SuspendUser(context.Background(), owner, "", "root", e.clock.now())
	require.NoError(t, err)
	cred := lost.authn.create(t, begin["options"].(map[string]any), e.base)
	status, r = lost.json("/passkey/register/finish?ceremony="+begin["ceremony"].(string)+"&next=/account", cred)
	assert.Equal(t, http.StatusForbidden, status)
	assert.Equal(t, suspendedText, r["error"])
	u, _ := e.store.UserByEmail(context.Background(), owner)
	keys, _ := e.store.Passkeys(context.Background(), u.ID)
	assert.Len(t, keys, 1, "no new passkey, and the old one was not removed")
}

// A blocked address can't sign up, and an account with it can't sign in (FR-197).
func TestBlockedAddress(t *testing.T) {
	e := setupWith(t, func(c *account.Config) { c.Operator = operator })
	ctx := context.Background()
	_, _, err := e.store.BlockEmail(ctx, "spammer@example.com", "", "root", e.clock.now())
	require.NoError(t, err)
	want := "This email address can't be used on this relay. To ask about it, write to relay-owner@example.org."

	b := e.browser()
	status, r := b.startEmail(" Spammer@Example.com ", false)
	assert.Equal(t, http.StatusForbidden, status)
	assert.Equal(t, want, r["error"])
	assert.Empty(t, e.mail.Sent(), "no code is sent")
	_, err = e.store.UserByEmail(ctx, "spammer@example.com")
	require.ErrorIs(t, err, store.ErrNotFound, "and no account is created")

	// An existing account whose address is blocked afterwards.
	b.signUp()
	_, suspended, err := e.store.BlockEmail(ctx, owner, "", "root", e.clock.now())
	require.NoError(t, err)
	require.True(t, suspended)
	assert.Equal(t, http.StatusFound, b.get("/account").status)
	status, r = b.startEmail(owner, false)
	assert.Equal(t, http.StatusForbidden, status)
	assert.Equal(t, want, r["error"])
	status, _ = b.signIn("signin", nil)
	assert.Equal(t, http.StatusForbidden, status)

	// Other addresses are not affected.
	status, r = e.browser().startEmail("someone@example.com", false)
	assert.Equal(t, http.StatusOK, status, r)
}

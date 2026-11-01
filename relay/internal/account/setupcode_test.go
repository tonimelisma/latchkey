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

const setupCode = "K7PQ-M2XD-9RTA"

// setupNoMail is a personal relay with a setup code and no email server (spec 009 FR-907, FR-908).
func setupNoMail(t *testing.T) *env {
	t.Helper()
	return setupWith(t, func(c *account.Config) {
		c.Mailer = nil
		c.SetupCode = setupCode
	})
}

// codeFlowWith runs email → a given code → passkey for the owner.
func (b *browser) codeFlowWith(code, purpose string) {
	b.e.t.Helper()
	status, r := b.startEmail(owner, purpose == store.PurposeRecover)
	require.Equal(b.e.t, http.StatusOK, status, r)
	status, t := b.confirmCode(code, purpose)
	require.Equal(b.e.t, http.StatusOK, status, t)
	status, done := b.createPasskey(t["ticket"].(string))
	require.Equal(b.e.t, http.StatusOK, status, done)
}

func TestSetupCodeClaimsAFreshRelay(t *testing.T) {
	e := setupNoMail(t)
	b := e.browser()
	status, r := b.startEmail(owner, false)
	require.Equal(t, http.StatusOK, status, r)
	assert.Equal(t, map[string]any{"step": "code", "purpose": "verify", "given": true}, r, "nothing is emailed")

	status, ticket := b.confirmCode(" k7pq m2xd 9rta ", store.PurposeVerify)
	require.Equal(t, http.StatusOK, status, "case, spaces, and dashes don't matter: %v", ticket)
	status, done := b.createPasskey(ticket["ticket"].(string))
	require.Equal(t, http.StatusOK, status, done)

	u, err := e.store.UserByEmail(context.Background(), owner)
	require.NoError(t, err)
	assert.False(t, u.EmailVerifiedAt.IsZero())
	assert.Equal(t, http.StatusOK, b.get("/account").status)
}

func TestWrongSetupCodesAreLimited(t *testing.T) {
	e := setupNoMail(t)
	b := e.browser()
	b.startEmail(owner, false)
	for range account.SetupCodeTries {
		status, r := b.confirmCode("AAAA-BBBB-CCCC", store.PurposeVerify)
		require.Equal(t, http.StatusBadRequest, status)
		assert.Contains(t, r["error"], "setup code")
	}
	status, r := b.confirmCode(setupCode, store.PurposeVerify)
	assert.Equal(t, http.StatusTooManyRequests, status, "even the right code waits after too many wrong ones")
	assert.Contains(t, r["error"], "minutes")
	e.clock.advance(11 * time.Minute)
	status, _ = b.confirmCode(setupCode, store.PurposeVerify)
	assert.Equal(t, http.StatusOK, status, "and works again later")
}

func TestSignUpClosesOnceClaimed(t *testing.T) {
	e := setupNoMail(t)
	e.browser().codeFlowWith(setupCode, store.PurposeVerify)

	stranger := e.browser()
	status, r := stranger.json("/auth/email", map[string]any{"email": "stranger@example.com"})
	assert.Equal(t, http.StatusForbidden, status)
	assert.Contains(t, r["error"], "closed")
	status, _ = stranger.json("/auth/code", map[string]string{
		"email": "stranger@example.com", "code": setupCode, "purpose": store.PurposeVerify,
	})
	assert.NotEqual(t, http.StatusOK, status, "the setup code opens nothing any more")
}

// With an email server too, the first account still needs the setup code; later ones are emailed
// codes as usual.
func TestSetupCodeWithAnEmailServer(t *testing.T) {
	e := setupWith(t, func(c *account.Config) { c.SetupCode = setupCode })
	status, r := e.browser().startEmail(owner, false)
	require.Equal(t, http.StatusOK, status)
	assert.Equal(t, true, r["given"])
	assert.Empty(t, e.mail.Sent(), "the first sign-up isn't emailed")
	status, _ = e.browser().confirmCode("123456", store.PurposeVerify)
	assert.Equal(t, http.StatusBadRequest, status, "an emailed-style code doesn't claim the relay")

	e.browser().codeFlowWith(setupCode, store.PurposeVerify)
	status, r = e.browser().json("/auth/email", map[string]any{"email": "friend@example.com"})
	require.Equal(t, http.StatusOK, status, r)
	assert.Nil(t, r["given"])
	assert.Len(t, e.mail.Sent(), 1, "the next person gets an emailed code")
}

func TestRecoveryCodeFromTheOperator(t *testing.T) {
	e := setupNoMail(t)
	first := e.browser()
	first.codeFlowWith(setupCode, store.PurposeVerify)
	ctx := context.Background()

	lost := e.browser()
	status, r := lost.startEmail(owner, true)
	require.Equal(t, http.StatusOK, status)
	assert.Equal(t, map[string]any{"step": "code", "purpose": "recover", "given": true}, r)

	code, err := account.RecoveryCode(ctx, e.store, owner, e.clock.now())
	require.NoError(t, err)
	status, ticket := lost.confirmCode(code, store.PurposeRecover)
	require.Equal(t, http.StatusOK, status, ticket)
	status, done := lost.createPasskey(ticket["ticket"].(string))
	require.Equal(t, http.StatusOK, status, done, "recovered without any email")
	assert.Equal(t, http.StatusOK, lost.get("/account").status)

	status, _ = e.browser().confirmCode(code, store.PurposeRecover)
	assert.Equal(t, http.StatusBadRequest, status, "used once")

	code, err = account.RecoveryCode(ctx, e.store, owner, e.clock.now())
	require.NoError(t, err)
	e.clock.advance(61 * time.Minute)
	status, _ = e.browser().confirmCode(code, store.PurposeRecover)
	assert.Equal(t, http.StatusBadRequest, status, "expired after an hour")

	_, err = account.RecoveryCode(ctx, e.store, "nobody@example.com", e.clock.now())
	assert.ErrorIs(t, err, store.ErrNotFound)
}

func TestNoEmailServerNeedsASetupCode(t *testing.T) {
	_, err := account.New(context.Background(), account.Config{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "SETUP_CODE")
}

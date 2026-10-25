package store_test

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// account is a verified user with everything a suspension must end or keep.
func account(t *testing.T, s *store.Store, email string) (store.User, store.Device) {
	t.Helper()
	ctx := context.Background()
	u, err := s.CreateUser(ctx, email, t0)
	require.NoError(t, err)
	require.NoError(t, s.VerifyEmail(ctx, u.ID, t0))
	require.NoError(t, s.AddPasskey(ctx, u.ID, []byte("cred-"+email), []byte(`{}`), t0))
	require.NoError(t, s.UpdatePasskey(ctx, []byte("cred-"+email), []byte(`{}`), t0.Add(2*time.Hour)))
	require.NoError(t, s.CreateSession(ctx, []byte("sess-"+email), u.ID, t0.Add(time.Hour), t0.Add(24*time.Hour)))
	d, err := s.CreateDevice(ctx, store.NewDevice{UserID: u.ID, Name: "Mac", PublicKey: []byte("key")}, t0)
	require.NoError(t, err)
	addGrant(t, s, "req-"+email, u.ID, "Claude", t0)
	putToken(t, s, "refresh-"+email, store.KindRefresh, "req-"+email, u.ID, t0, 24*time.Hour)
	require.NoError(t, s.CreateEmailCode(ctx, u.ID, store.PurposeRecover, []byte("code-"+email), t0.Add(time.Hour)))
	require.NoError(t, s.AddAudit(ctx, store.AuditEntry{UserID: u.ID, DeviceID: d.ID, At: t0, Tool: "x", Outcome: store.OutcomeOK}))
	return u, d
}

// Suspending ends the account's browser sign-ins, emailed codes, and every Claude approval in
// one step, records who did it, and deletes nothing else (FR-196).
func TestSuspendUser(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u, d := account(t, s, "a@example.com")
	other, _ := account(t, s, "b@example.com")
	now := t0.Add(3 * time.Hour)

	_, changed, err := s.SuspendUser(ctx, "nobody@example.com", "x", "root", now)
	require.ErrorIs(t, err, store.ErrNotFound)
	assert.False(t, changed)

	got, changed, err := s.SuspendUser(ctx, "a@example.com", "sending spam", "root", now)
	require.NoError(t, err)
	assert.True(t, changed)
	assert.Equal(t, u.ID, got.ID)

	su, err := s.User(ctx, u.ID)
	require.NoError(t, err, "the account is still there")
	assert.Equal(t, now, su.SuspendedAt)
	assert.Equal(t, "sending spam", su.SuspendedReason)
	_, err = s.Session(ctx, []byte("sess-a@example.com"), now)
	require.ErrorIs(t, err, store.ErrNotFound, "every browser sign-in is ended")
	_, err = s.OAuthRequest(ctx, store.KindRefresh, "refresh-a@example.com")
	require.ErrorIs(t, err, store.ErrNotFound, "every Claude approval is removed")
	grants, err := s.LiveGrants(ctx, u.ID, now, 50)
	require.NoError(t, err)
	assert.Empty(t, grants)
	require.ErrorIs(t, s.CheckEmailCode(ctx, u.ID, store.PurposeRecover, []byte("code-a@example.com"), now), store.ErrNotFound,
		"a recovery code already sent no longer works")

	// Nothing else is deleted: the Mac stays paired, the passkey and the activity log stay.
	dev, err := s.ActiveDevice(ctx, u.ID)
	require.NoError(t, err)
	assert.Equal(t, d.ID, dev.ID)
	assert.NotNil(t, dev.PublicKey)
	keys, err := s.Passkeys(ctx, u.ID)
	require.NoError(t, err)
	assert.Len(t, keys, 1)
	audit, err := s.AuditForUser(ctx, u.ID, 10)
	require.NoError(t, err)
	assert.Len(t, audit, 1)

	// The other account is untouched.
	_, err = s.Session(ctx, []byte("sess-b@example.com"), now)
	require.NoError(t, err)
	_, err = s.OAuthRequest(ctx, store.KindRefresh, "refresh-b@example.com")
	require.NoError(t, err)
	ou, err := s.User(ctx, other.ID)
	require.NoError(t, err)
	assert.True(t, ou.SuspendedAt.IsZero())

	// A session that slips in while suspended is not honored either.
	require.NoError(t, s.CreateSession(ctx, []byte("late"), u.ID, now, now.Add(time.Hour)))
	_, err = s.Session(ctx, []byte("late"), now)
	require.ErrorIs(t, err, store.ErrNotFound)

	// Recorded: who, what, when, and the account's IDs for the running relay.
	log, err := s.OperatorLogAfter(ctx, 0)
	require.NoError(t, err)
	require.Len(t, log, 1)
	assert.Equal(t, store.OperatorEntry{
		ID: log[0].ID, At: now, Actor: "root", Action: store.OpSuspend, Email: "a@example.com",
		UserID: u.ID, DeviceID: d.ID, Detail: "sending spam",
	}, log[0])

	// Again: nothing changes, nothing is recorded.
	_, changed, err = s.SuspendUser(ctx, "a@example.com", "again", "root", now)
	require.NoError(t, err)
	assert.False(t, changed)
	log, _ = s.OperatorLogAfter(ctx, 0)
	assert.Len(t, log, 1)

	// Lifting it restores sign-in; the approvals stay gone.
	_, changed, err = s.UnsuspendUser(ctx, "a@example.com", "root", now.Add(time.Hour))
	require.NoError(t, err)
	assert.True(t, changed)
	su, _ = s.User(ctx, u.ID)
	assert.True(t, su.SuspendedAt.IsZero())
	assert.Empty(t, su.SuspendedReason)
	_, err = s.Session(ctx, []byte("late"), now)
	require.NoError(t, err)
	_, changed, err = s.UnsuspendUser(ctx, "a@example.com", "root", now)
	require.NoError(t, err)
	assert.False(t, changed, "not suspended any more")
	_, _, err = s.UnsuspendUser(ctx, "nobody@example.com", "root", now)
	require.ErrorIs(t, err, store.ErrNotFound)

	last, err := s.LastOperatorLogID(ctx)
	require.NoError(t, err)
	newer, err := s.OperatorLogAfter(ctx, log[0].ID)
	require.NoError(t, err)
	require.Len(t, newer, 1)
	assert.Equal(t, store.OpUnsuspend, newer[0].Action)
	assert.Equal(t, last, newer[0].ID)
}

func TestDeleteUserByOperator(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u, d := account(t, s, "a@example.com")
	_, err := s.DeleteUserByOperator(ctx, "nobody@example.com", "root", t0)
	require.ErrorIs(t, err, store.ErrNotFound)
	got, err := s.DeleteUserByOperator(ctx, "a@example.com", "root", t0)
	require.NoError(t, err)
	assert.Equal(t, u.ID, got.ID)
	_, err = s.User(ctx, u.ID)
	require.ErrorIs(t, err, store.ErrNotFound)
	_, err = s.Device(ctx, d.ID)
	require.ErrorIs(t, err, store.ErrNotFound, "as with the Owner's own Delete account")
	log, err := s.OperatorLogAfter(ctx, 0)
	require.NoError(t, err)
	require.Len(t, log, 1, "the record outlives the account")
	assert.Equal(t, store.OpDelete, log[0].Action)
	assert.Equal(t, u.ID, log[0].UserID)
	assert.Equal(t, d.ID, log[0].DeviceID)
}

// Blocking an address suspends its account if there is one; unblocking removes only the block
// (FR-197).
func TestBlockAndUnblock(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u, _ := account(t, s, "a@example.com")

	changed, suspended, err := s.BlockEmail(ctx, "a@example.com", "abuse", "root", t0)
	require.NoError(t, err)
	assert.True(t, changed)
	assert.True(t, suspended, "the existing account is suspended with it")
	su, _ := s.User(ctx, u.ID)
	assert.False(t, su.SuspendedAt.IsZero())

	changed, suspended, err = s.BlockEmail(ctx, "new@example.com", "", "root", t0.Add(time.Minute))
	require.NoError(t, err)
	assert.True(t, changed)
	assert.False(t, suspended, "no account yet")
	changed, _, err = s.BlockEmail(ctx, "new@example.com", "", "root", t0)
	require.NoError(t, err)
	assert.False(t, changed, "already blocked")

	for email, want := range map[string]bool{"a@example.com": true, "new@example.com": true, "free@example.com": false} {
		blocked, err := s.EmailBlocked(ctx, email)
		require.NoError(t, err)
		assert.Equal(t, want, blocked, email)
	}
	list, err := s.BlockedEmails(ctx)
	require.NoError(t, err)
	require.Len(t, list, 2)
	assert.Equal(t, store.BlockedEmail{Email: "a@example.com", At: t0, Reason: "abuse"}, list[0])

	changed, err = s.UnblockEmail(ctx, "a@example.com", "root", t0)
	require.NoError(t, err)
	assert.True(t, changed)
	changed, err = s.UnblockEmail(ctx, "a@example.com", "root", t0)
	require.NoError(t, err)
	assert.False(t, changed)
	blocked, _ := s.EmailBlocked(ctx, "a@example.com")
	assert.False(t, blocked)
	su, _ = s.User(ctx, u.ID)
	assert.False(t, su.SuspendedAt.IsZero(), "unblocking does not lift the suspension")

	log, _ := s.OperatorLogAfter(ctx, 0)
	var actions []string
	for _, e := range log {
		actions = append(actions, e.Action)
	}
	assert.Equal(t, []string{store.OpBlock, store.OpBlock, store.OpUnblock}, actions)
	assert.Equal(t, u.ID, log[0].UserID, "so the running relay closes that account's connections")
}

// The list of accounts holds no secrets: addresses, dates, and counts.
func TestAccounts(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	account(t, s, "b@example.com")
	_, err := s.CreateUser(ctx, "a@example.com", t0.Add(time.Minute)) // never verified, no Mac
	require.NoError(t, err)
	_, _, err = s.SuspendUser(ctx, "b@example.com", "", "root", t0)
	require.NoError(t, err)

	list, err := s.Accounts(ctx, t0)
	require.NoError(t, err)
	require.Len(t, list, 2)
	assert.Equal(t, store.AccountSummary{Email: "a@example.com", CreatedAt: t0.Add(time.Minute)}, list[0], "sorted by address")
	b := list[1]
	assert.Equal(t, "b@example.com", b.Email)
	assert.True(t, b.Verified)
	assert.True(t, b.Suspended)
	assert.True(t, b.HasMac)
	assert.Equal(t, 0, b.Approvals, "removed by the suspension")
	assert.Equal(t, t0.Add(2*time.Hour), b.LastSignIn, "the newest passkey use or browser sign-in")
}

func TestOperatorLogIsPurged(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	_, _, err := s.BlockEmail(ctx, "old@example.com", "", "root", t0)
	require.NoError(t, err)
	_, _, err = s.BlockEmail(ctx, "new@example.com", "", "root", t0.Add(400*24*time.Hour))
	require.NoError(t, err)
	require.NoError(t, s.PurgeOperatorLog(ctx, t0.Add(400*24*time.Hour).Add(-store.OperatorLogRetention)))
	log, err := s.OperatorLogAfter(ctx, 0)
	require.NoError(t, err)
	require.Len(t, log, 1)
	assert.Equal(t, "new@example.com", log[0].Email)
	list, _ := s.BlockedEmails(ctx)
	assert.Len(t, list, 2, "the blocks themselves stay")
}

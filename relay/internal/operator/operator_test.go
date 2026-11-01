package operator_test

import (
	"bytes"
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/operator"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

var t0 = time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)

type env struct {
	t     *testing.T
	store *store.Store
}

func setup(t *testing.T) *env {
	t.Helper()
	st, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "relay.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = st.Close() })
	return &env{t: t, store: st}
}

// run is one command, as `relay <args>` would run it; it returns what was printed.
func (e *env) run(args ...string) (string, error) {
	e.t.Helper()
	var out bytes.Buffer
	err := operator.Run(context.Background(), operator.Env{
		Store: e.store, Out: &out, Actor: "alex", Now: func() time.Time { return t0 },
	}, args)
	return out.String(), err
}

// ok is a command that must succeed and print exactly one line.
func (e *env) ok(args ...string) string {
	e.t.Helper()
	out, err := e.run(args...)
	require.NoError(e.t, err, strings.Join(args, " "))
	require.Equal(e.t, 1, strings.Count(out, "\n"), "one plain line, got %q", out)
	return strings.TrimSuffix(out, "\n")
}

func (e *env) user(email string) store.User {
	e.t.Helper()
	ctx := context.Background()
	u, err := e.store.CreateUser(ctx, email, t0.Add(-48*time.Hour))
	require.NoError(e.t, err)
	require.NoError(e.t, e.store.VerifyEmail(ctx, u.ID, t0.Add(-48*time.Hour)))
	return u
}

func (e *env) lastLog() store.OperatorEntry {
	e.t.Helper()
	log, err := e.store.OperatorLogAfter(context.Background(), 0)
	require.NoError(e.t, err)
	require.NotEmpty(e.t, log)
	return log[len(log)-1]
}

func TestAccountSuspendAndUnsuspend(t *testing.T) {
	e := setup(t)
	u := e.user("owner@example.com")
	ctx := context.Background()

	// The address is matched as sign-up stores it; the rest of the line is the reason.
	line := e.ok("account", "suspend", " Owner@Example.COM ", "sending", "spam")
	assert.Contains(t, line, "Suspended owner@example.com")
	got, err := e.store.User(ctx, u.ID)
	require.NoError(t, err)
	assert.Equal(t, t0, got.SuspendedAt)
	assert.Equal(t, "sending spam", got.SuspendedReason)
	entry := e.lastLog()
	assert.Equal(t, "alex", entry.Actor, "who")
	assert.Equal(t, store.OpSuspend, entry.Action, "what")
	assert.Equal(t, t0, entry.At, "when")
	assert.Equal(t, "owner@example.com", entry.Email)

	assert.Contains(t, e.ok("account", "suspend", "owner@example.com"), "already suspended")

	line = e.ok("account", "unsuspend", "OWNER@example.com")
	assert.Contains(t, line, "owner@example.com")
	got, _ = e.store.User(ctx, u.ID)
	assert.True(t, got.SuspendedAt.IsZero())
	assert.Equal(t, store.OpUnsuspend, e.lastLog().Action)
	assert.Contains(t, e.ok("account", "unsuspend", "owner@example.com"), "not suspended")

	// A reason is optional.
	e.ok("account", "suspend", "owner@example.com")
	got, _ = e.store.User(ctx, u.ID)
	assert.False(t, got.SuspendedAt.IsZero())
	assert.Empty(t, got.SuspendedReason)
}

func TestAccountDelete(t *testing.T) {
	e := setup(t)
	u := e.user("owner@example.com")
	line := e.ok("account", "delete", "Owner@example.com")
	assert.Contains(t, line, "Deleted owner@example.com")
	_, err := e.store.User(context.Background(), u.ID)
	require.ErrorIs(t, err, store.ErrNotFound)
	assert.Equal(t, store.OpDelete, e.lastLog().Action)
	assert.Equal(t, "alex", e.lastLog().Actor)
}

func TestBlockUnblockAndList(t *testing.T) {
	e := setup(t)
	u := e.user("owner@example.com")
	ctx := context.Background()
	assert.Contains(t, e.ok("block", "list"), "No addresses are blocked")

	line := e.ok("block", "Owner@Example.com", "abuse", "report")
	assert.Contains(t, line, "Blocked owner@example.com")
	assert.Contains(t, line, "suspended", "blocking suspends the existing account")
	got, _ := e.store.User(ctx, u.ID)
	assert.False(t, got.SuspendedAt.IsZero())
	blocked, _ := e.store.EmailBlocked(ctx, "owner@example.com")
	assert.True(t, blocked)
	assert.Equal(t, "abuse report", e.lastLog().Detail)

	line = e.ok("block", "stranger@example.com")
	assert.Contains(t, line, "Blocked stranger@example.com")
	assert.NotContains(t, line, "suspended")
	assert.Contains(t, e.ok("block", "stranger@example.com"), "already blocked")

	out, err := e.run("block", "list")
	require.NoError(t, err)
	lines := strings.Split(strings.TrimSpace(out), "\n")
	require.Len(t, lines, 2)
	assert.Contains(t, lines[0], "owner@example.com")
	assert.Contains(t, lines[0], "abuse report")
	assert.Contains(t, lines[0], "2026-10-25")
	assert.Contains(t, lines[1], "stranger@example.com")

	line = e.ok("unblock", "OWNER@example.com")
	assert.Contains(t, line, "Unblocked owner@example.com")
	assert.Contains(t, line, "still suspended", "and says what is left to do")
	blocked, _ = e.store.EmailBlocked(ctx, "owner@example.com")
	assert.False(t, blocked)
	assert.Equal(t, store.OpUnblock, e.lastLog().Action)
	assert.Contains(t, e.ok("unblock", "owner@example.com"), "not blocked")
	assert.NotContains(t, e.ok("unblock", "stranger@example.com"), "suspended")
}

// The list shows addresses, dates, and counts: nothing that could sign anyone in.
func TestAccountList(t *testing.T) {
	e := setup(t)
	out, err := e.run("account", "list")
	require.NoError(t, err)
	assert.Equal(t, "No accounts.\n", out)

	ctx := context.Background()
	u := e.user("owner@example.com")
	require.NoError(t, e.store.CreateSession(ctx, []byte("session-secret"), u.ID, t0.Add(-time.Hour), t0.Add(time.Hour)))
	_, err = e.store.CreateDevice(ctx, store.NewDevice{UserID: u.ID, Name: "Mac", PublicKey: []byte("device-key")}, t0)
	require.NoError(t, err)
	require.NoError(t, e.store.AddGrant(ctx, store.Grant{RequestID: "req", ID: "grt_secretish", UserID: u.ID, ClientID: "c", ApprovedAt: t0}))
	require.NoError(t, e.store.PutOAuthRequest(ctx, store.OAuthRequest{
		Signature: "token-signature", Kind: store.KindRefresh, RequestID: "req", ClientID: "c", UserID: u.ID,
		RequestedAt: t0, SessionJSON: []byte(`{}`), ExpiresAt: t0.Add(time.Hour),
	}))
	e.user("zed@example.com")
	e.ok("account", "suspend", "zed@example.com")

	out, err = e.run("account", "list")
	require.NoError(t, err)
	lines := strings.Split(strings.TrimSpace(out), "\n")
	require.Len(t, lines, 4, out)
	for _, col := range []string{"EMAIL", "CREATED", "LAST SIGN-IN", "STATUS", "MAC", "CLAUDE APPS"} {
		assert.Contains(t, lines[0], col)
	}
	owner := strings.Fields(lines[1])
	assert.Equal(t, []string{"owner@example.com", "2026-10-23", "2026-10-25", "active", "yes", "1"}, owner)
	zed := strings.Fields(lines[2])
	assert.Equal(t, []string{"zed@example.com", "2026-10-23", "never", "suspended", "no", "0"}, zed)
	assert.Equal(t, "2 accounts, 1 suspended.", lines[3])
	for _, secret := range []string{"session-secret", "device-key", "token-signature", "grt_secretish", u.ID} {
		assert.NotContains(t, out, secret)
	}
}

// Every failure is an error (the command exits non-zero) and changes nothing.
// A relay without an email server: whoever runs it gives the Owner a recovery code (spec 009
// FR-914). The code itself is checked by the account package's tests.
func TestAccountRecoveryCode(t *testing.T) {
	e := setup(t)
	e.user("owner@example.com")
	line := e.ok("account", "recovery-code", "Owner@Example.com")
	assert.Regexp(t, `^Recovery code for owner@example\.com: \d{6} \(works once, until 13:00 UTC\)\. `, line)
	assert.Contains(t, line, "Lost your passkey?")
}

func TestFailures(t *testing.T) {
	e := setup(t)
	e.user("owner@example.com")
	cases := map[string][]string{
		"recovery code no account": {"account", "recovery-code", "nobody@example.com"},
		"recovery code no address": {"account", "recovery-code"},
		"no such account":          {"account", "suspend", "nobody@example.com"},
		"unsuspend no account":     {"account", "unsuspend", "nobody@example.com"},
		"delete no account":        {"account", "delete", "nobody@example.com"},
		"not an address":           {"account", "suspend", "owner"},
		"block not an address":     {"block", "everyone"},
		"unblock not an address":   {"unblock", "x"},
		"missing address":          {"account", "suspend"},
		"delete missing address":   {"account", "delete"},
		"delete with extra words":  {"account", "delete", "owner@example.com", "now"},
		"unknown account command":  {"account", "promote", "owner@example.com"},
		"account alone":            {"account"},
		"block alone":              {"block"},
		"unblock alone":            {"unblock"},
		"unknown command":          {"acount", "list"},
		"list with extra words":    {"account", "list", "all"},
		"nothing":                  {},
	}
	for name, args := range cases {
		t.Run(name, func(t *testing.T) {
			out, err := e.run(args...)
			require.Error(t, err)
			assert.Empty(t, out, "nothing is reported as done")
		})
	}
	log, err := e.store.OperatorLogAfter(context.Background(), 0)
	require.NoError(t, err)
	assert.Empty(t, log, "and nothing was recorded")
	_, err = e.run("acount", "list")
	require.ErrorIs(t, err, operator.ErrUsage)
	assert.Contains(t, operator.Usage, "account suspend <email> [reason]")
}

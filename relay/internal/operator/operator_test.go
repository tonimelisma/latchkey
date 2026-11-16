package operator_test

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/operator"
	"github.com/tonimelisma/latchkey/relay/internal/store"
	"github.com/tonimelisma/latchkey/relay/internal/trace"
)

var t0 = time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)

type env struct {
	t      *testing.T
	store  *store.Store
	traces *trace.Store
	errOut bytes.Buffer
}

func setup(t *testing.T) *env {
	t.Helper()
	st, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "relay.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = st.Close() })
	key, err := st.DeriveKey(trace.KeyInfo)
	require.NoError(t, err)
	ts, err := trace.New(trace.Options{
		Dir: filepath.Join(t.TempDir(), "traces"), Key: key, FreeSpace: func(string) (uint64, error) { return 100 << 30, nil },
	})
	require.NoError(t, err)
	return &env{t: t, store: st, traces: ts}
}

// run is one command, as `relay <args>` would run it; it returns what was printed.
func (e *env) run(args ...string) (string, error) {
	e.t.Helper()
	var out bytes.Buffer
	err := operator.Run(context.Background(), operator.Env{
		Store: e.store, Traces: e.traces, Out: &out, Err: &e.errOut, Actor: "alex", Now: func() time.Time { return t0 },
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

// FR-687: the operator's delete removes the account's traces too, and only that account's.
func TestAccountDeleteRemovesTraces(t *testing.T) {
	e := setup(t)
	u := e.user("owner@example.com")
	other := e.user("zed@example.com")
	e.traces.Append(u.ID, t0, trace.Event("mac_connected", "app 1.0", ""))
	e.traces.Append(other.ID, t0, trace.Event("mac_connected", "app 1.0", ""))
	e.ok("account", "delete", "owner@example.com")
	n := 0
	_, err := e.traces.Each(u.ID, "", "", func(trace.Line) error { n++; return nil })
	require.NoError(t, err)
	assert.Zero(t, n, "the account's traces are gone")
	_, err = e.traces.Each(other.ID, "", "", func(trace.Line) error { n++; return nil })
	require.NoError(t, err)
	assert.Equal(t, 1, n, "another account's stay")
}

// FR-685, FR-686: the operator exports an account's trace to standard output, oldest first, one
// export line each with the account's current address, from and to a day (both included).
func TestTraceExport(t *testing.T) {
	e := setup(t)
	u := e.user("owner@example.com")
	day := func(d int) time.Time { return time.Date(2026, 11, d, 12, 0, 0, 0, time.UTC) }
	for _, d := range []int{16, 14, 15} {
		e.traces.Append(u.ID, day(d), trace.Line{
			Kind: trace.KindAction, Tool: "shell_run", Arguments: trace.JSONOrString([]byte(`{"command":"date"}`)),
			Result: json.RawMessage(`[{"type":"text","text":"ok"}]`), Outcome: "ok", CallID: "call_" + strconv.Itoa(d), Machine: "Mac",
		})
	}
	tools := func(out string) []string {
		var ids []string
		for _, l := range strings.Split(strings.TrimSuffix(out, "\n"), "\n") {
			if l == "" {
				continue
			}
			var m map[string]any
			require.NoError(t, json.Unmarshal([]byte(l), &m), l)
			assert.Equal(t, "owner@example.com", m["account"])
			assert.Equal(t, "relay", m["source"])
			ids = append(ids, m["call_id"].(string))
		}
		return ids
	}
	out, err := e.run("trace", "export", "Owner@Example.com")
	require.NoError(t, err)
	assert.Equal(t, []string{"call_14", "call_15", "call_16"}, tools(out))
	assert.JSONEq(t, `{"v":1,"source":"relay","machine":"Mac","time":"2026-11-14T12:00:00.000Z","kind":"action",
		"tool":"shell_run","arguments":{"command":"date"},"result":[{"type":"text","text":"ok"}],"isError":false,
		"durationMS":0,"call_id":"call_14","client":null,"outcome":"ok","account":"owner@example.com"}`, strings.Split(out, "\n")[0])
	out, err = e.run("trace", "export", "owner@example.com", "--from", "2026-11-15")
	require.NoError(t, err)
	assert.Equal(t, []string{"call_15", "call_16"}, tools(out))
	out, err = e.run("trace", "export", "owner@example.com", "--to", "2026-11-15", "--from", "2026-11-15")
	require.NoError(t, err)
	assert.Equal(t, []string{"call_15"}, tools(out))
	out, err = e.run("trace", "export", "owner@example.com", "--from=2026-11-16")
	require.NoError(t, err)
	assert.Equal(t, []string{"call_16"}, tools(out))
	assert.Empty(t, e.errOut.String())

	// Lines that can't be read are left out and counted on standard error.
	require.NoError(t, os.WriteFile(filepath.Join(e.traces.Dir(), u.ID, "2026-11-17.trace"), []byte("cut sh"), 0o600))
	out, err = e.run("trace", "export", "owner@example.com")
	require.NoError(t, err)
	assert.Len(t, tools(out), 3)
	assert.Contains(t, e.errOut.String(), "1 line couldn't be read and was left out")

	// An account with no trace exports nothing, and that is no error.
	e.user("zed@example.com")
	out, err = e.run("trace", "export", "zed@example.com")
	require.NoError(t, err)
	assert.Empty(t, out)
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
		"trace alone":              {"trace"},
		"trace export no address":  {"trace", "export"},
		"trace export no account":  {"trace", "export", "nobody@example.com"},
		"trace export bad day":     {"trace", "export", "owner@example.com", "--from", "15.11.2026"},
		"trace export no day":      {"trace", "export", "owner@example.com", "--to"},
		"trace export odd flag":    {"trace", "export", "owner@example.com", "--since", "2026-11-15"},
		"trace export two emails":  {"trace", "export", "owner@example.com", "zed@example.com"},
		"trace unknown":            {"trace", "import", "owner@example.com"},
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
	assert.Contains(t, operator.Usage, "trace export <email> [--from YYYY-MM-DD] [--to YYYY-MM-DD]")
}

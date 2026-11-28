package server

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/events"
	"github.com/tonimelisma/latchkey/relay/internal/trace"
)

type bearerTransport struct{ token string }

func (b bearerTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	r = r.Clone(r.Context())
	r.Header.Set("Authorization", "Bearer "+b.token)
	return http.DefaultTransport.RoundTrip(r)
}

func (h *harness) traceLines(userID string) []trace.Line {
	h.t.Helper()
	var out []trace.Line
	_, err := h.traces.Each(userID, "", "", func(l trace.Line) error {
		out = append(out, l)
		return nil
	})
	require.NoError(h.t, err)
	return out
}

func (h *harness) waitTrace(userID string, ok func(trace.Line) bool) trace.Line {
	h.t.Helper()
	var found trace.Line
	require.Eventually(h.t, func() bool {
		for _, l := range h.traceLines(userID) {
			if ok(l) {
				found = l
				return true
			}
		}
		return false
	}, 5*time.Second, 10*time.Millisecond)
	return found
}

func tool(name string) func(trace.Line) bool {
	return func(l trace.Line) bool { return l.Tool == name }
}

// FR-683, FR-685, FR-686: through the whole relay, with a real MCP client: the call and the
// account's events go to its trace, and both exports give them back with the account's address.
func TestTraceThroughTheWholeRelay(t *testing.T) {
	h := newHarness(t, nil)
	o := h.owner("owner@example.com")
	h.dial(o.mac())
	client := h.registerClient(claudeCallback)
	access, _ := o.approve(client, claudeCallback)

	c := mcp.NewClient(&mcp.Implementation{Name: "claude-ai", Version: "1"}, nil)
	cs, err := c.Connect(tctx(t), &mcp.StreamableClientTransport{
		Endpoint: h.base + "/mcp", HTTPClient: &http.Client{Transport: bearerTransport{access}}, MaxRetries: -1,
	}, nil)
	require.NoError(t, err)
	t.Cleanup(func() { _ = cs.Close() })
	res, err := cs.CallTool(tctx(t), &mcp.CallToolParams{Name: "battery_status", Arguments: map[string]any{"machine": "Mac"}})
	require.NoError(t, err)
	require.False(t, res.IsError)

	call := h.waitTrace(o.user.ID, tool("battery_status"))
	assert.Equal(t, trace.KindAction, call.Kind)
	assert.JSONEq(t, `{"machine":"Mac"}`, string(call.Arguments))
	assert.Contains(t, string(call.Result), "battery")
	assert.Equal(t, "claude-ai", call.Client)
	assert.Equal(t, "Mac", call.Machine)
	audit, err := h.db.AuditForUser(context.Background(), o.user.ID, 1)
	require.NoError(t, err)
	assert.Equal(t, audit[0].CallID, call.CallID, "the trace and the audit name the call alike")

	connected := h.waitTrace(o.user.ID, tool(events.MacConnected))
	assert.Equal(t, trace.KindEvent, connected.Kind)
	assert.Equal(t, "Mac", connected.Machine)
	approved := h.waitTrace(o.user.ID, tool(events.ClaudeApproved))
	assert.Contains(t, string(approved.Result), "Claude")

	download := o.get("/account/trace")
	require.Equal(t, http.StatusOK, download.status)
	assert.Contains(t, download.body, `"tool":"battery_status"`)
	assert.Contains(t, download.body, `"tool":"mac_connected"`)
	assert.Contains(t, download.body, `"account":"owner@example.com"`)
	exported := h.command("trace", "export", "owner@example.com")
	assert.Equal(t, download.body, exported, "the operator's export and the account's download are the same lines")
}

// FR-684: below 2 GiB free the relay writes no trace and records traces_paused once, as an
// operator event; with room again, traces_resumed, and writing goes on. Calls work throughout.
func TestLowDiskPausesTraces(t *testing.T) {
	h := newHarness(t, nil)
	o := h.owner("owner@example.com")
	h.free.Store(1 << 30)
	h.dial(o.mac())
	h.event(o.user.ID, events.MacConnected, "")
	paused := h.event("", events.TracesPaused, "")
	assert.Contains(t, paused.Detail, "1.0 GiB free")
	assert.Empty(t, paused.UserID)
	assert.Empty(t, h.traceLines(o.user.ID), "nothing written while the disk is low")

	h.free.Store(3 << 30)
	h.dial(o.mac())
	h.event("", events.TracesResumed, "")
	h.waitTrace(o.user.ID, tool(events.MacConnected))
	all, err := h.db.Events(context.Background(), "", 100)
	require.NoError(t, err)
	n := 0
	for _, e := range all {
		if e.Kind == events.TracesPaused {
			n++
		}
	}
	assert.Equal(t, 1, n, "the pause is recorded once")
}

// FR-687: the operator's delete, while the relay runs, removes the account's traces, and the
// events that follow (its machines disconnected) don't make them again.
func TestOperatorDeleteRemovesTracesWhileTheRelayRuns(t *testing.T) {
	h := newHarness(t, nil)
	h.watch()
	o := h.owner("owner@example.com")
	mac := h.dial(o.mac())
	h.waitTrace(o.user.ID, tool(events.MacConnected))
	dir := filepath.Join(h.traces.Dir(), o.user.ID)
	require.DirExists(t, dir)

	h.command("account", "delete", "owner@example.com")
	assert.NoDirExists(t, dir)
	closeCode(t, mac)
	time.Sleep(200 * time.Millisecond) // the relay's follow-up of the deletion
	assert.NoDirExists(t, dir, "nothing written for an account that is gone")
}

// FR-687: a sign-up never finished is purged after a day, its traces with it.
func TestDailyPurgeRemovesTracesOfUnfinishedSignUps(t *testing.T) {
	h := newHarness(t, nil)
	ctx := context.Background()
	u, err := h.db.CreateUser(ctx, "half@example.com", time.Now().Add(-48*time.Hour))
	require.NoError(t, err)
	kept := h.owner("owner@example.com")
	h.traces.Append(u.ID, time.Now(), trace.Event(events.SignInCode, "code sent", ""))
	h.traces.Append(kept.user.ID, time.Now(), trace.Event(events.SignInPasskey, "signed in", ""))
	h.relay.Daily(ctx, time.Now(), slog.New(slog.DiscardHandler))
	assert.NoDirExists(t, filepath.Join(h.traces.Dir(), u.ID))
	assert.DirExists(t, filepath.Join(h.traces.Dir(), kept.user.ID))
}

// Every relay keeps traces in DATA_DIR/traces, sealed with a key derived from its key file.
func TestTraceOptions(t *testing.T) {
	h := newHarness(t, nil)
	opts, err := TraceOptions(h.db, "/data")
	require.NoError(t, err)
	assert.Equal(t, "/data/traces", opts.Dir)
	want, err := h.db.DeriveKey("latchkey relay traces v1")
	require.NoError(t, err)
	assert.Equal(t, want, opts.Key)
	assert.True(t, opts.AccountExists(h.owner("owner@example.com").user.ID))
	assert.False(t, opts.AccountExists("usr_gone"))
	info, err := os.Stat(h.traces.Dir())
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o700), info.Mode().Perm())
	assert.True(t, strings.HasSuffix(h.traces.Dir(), "/traces"))
}

// The requirements this file's tests cite (docs/requirements/; script/process-check).
// Validates: FR-683, FR-684, FR-685, FR-686, FR-687

package mcpserver_test

import (
	"bytes"
	"context"
	"encoding/json"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/mcpserver"
	"github.com/tonimelisma/latchkey/relay/internal/testagent"
	"github.com/tonimelisma/latchkey/relay/internal/trace"
)

// setupTraced is setup with the account's trace written to a folder of its own.
func setupTraced(t *testing.T) (*env, *trace.Store) {
	t.Helper()
	ts, err := trace.New(trace.Options{
		Dir: filepath.Join(t.TempDir(), "traces"), Key: bytes.Repeat([]byte{5}, 32),
		FreeSpace: func(string) (uint64, error) { return 100 << 30, nil },
	})
	require.NoError(t, err)
	return setupWith(t, mcpserver.Options{Traces: ts}), ts
}

func traced(t *testing.T, ts *trace.Store, userID string) []trace.Line {
	t.Helper()
	var out []trace.Line
	skipped, err := ts.Each(userID, "", "", func(l trace.Line) error {
		out = append(out, l)
		return nil
	})
	require.NoError(t, err)
	require.Zero(t, skipped)
	return out
}

// waitTraced waits for the call's one line: it is written as its answer goes out.
func waitTraced(t *testing.T, ts *trace.Store, userID string) []trace.Line {
	t.Helper()
	const n = 1
	var got []trace.Line
	require.Eventually(t, func() bool {
		got = traced(t, ts, userID)
		return len(got) >= n
	}, 5*time.Second, 10*time.Millisecond)
	require.Len(t, got, n)
	return got
}

// contentJSON is the content array exactly as Claude got it.
func contentJSON(t *testing.T, res *mcp.CallToolResult) string {
	t.Helper()
	data, err := json.Marshal(res.Content)
	require.NoError(t, err)
	return string(data)
}

// FR-683: a call that worked is traced with the arguments as Claude sent them (machine
// included), the whole result as Claude got it (the status line and images included), the call
// id the machine got, the Claude app, the machine, the outcome, and the duration.
func TestTraceOfACallThatWorked(t *testing.T) {
	e, ts := setupTraced(t)
	e.pair()
	e.agent.Handler = func(_ context.Context, call *agentproto.Call) *agentproto.Result {
		return &agentproto.Result{ID: call.ID, Content: []byte(`[{"type":"text","text":"82% <on AC>"},{"type":"image","mimeType":"image/png","data":"iVBORw0KGgo="}]`)}
	}
	c := e.connectMac()
	cs := e.client(stateful, nil)
	args := map[string]any{"machine": "Sam's MacBook Pro", "detail": "full & <exact>"}
	before := time.Now().UTC()
	res, err := cs.CallTool(ctx(t), &mcp.CallToolParams{Name: "battery_status", Arguments: args})
	require.NoError(t, err)
	sent := <-c.Calls

	got := waitTraced(t, ts, e.user.ID)
	l := got[0]
	assert.Equal(t, trace.KindAction, l.Kind)
	assert.Equal(t, "relay", l.Source)
	assert.Equal(t, "battery_status", l.Tool)
	assert.JSONEq(t, `{"machine":"Sam's MacBook Pro","detail":"full & <exact>"}`, string(l.Arguments))
	assert.Contains(t, string(l.Arguments), "full & <exact>", "not escaped")
	assert.JSONEq(t, contentJSON(t, res), string(l.Result), "the result as Claude got it")
	assert.Contains(t, string(l.Result), "iVBORw0KGgo=", "images included")
	assert.Contains(t, string(l.Result), "Sam's MacBook Pro", "the status line included")
	require.Len(t, res.Content, 3)
	assert.False(t, l.IsError)
	assert.Equal(t, "ok", l.Outcome)
	assert.Equal(t, sent.ID, l.CallID, "joined to the machine's line by the call id")
	assert.Equal(t, "test-client", l.Client)
	assert.Equal(t, "Sam's MacBook Pro", l.Machine)
	assert.GreaterOrEqual(t, l.DurationMS, int64(0))
	at, err := time.Parse(time.RFC3339Nano, l.Time)
	require.NoError(t, err)
	assert.WithinDuration(t, before, at, 2*time.Second)
	assert.Empty(t, l.Account, "the account is added at export only")
}

// The machine's own error is traced as an error with its words.
func TestTraceOfAMachineError(t *testing.T) {
	e, ts := setupTraced(t)
	e.pair()
	e.agent.Handler = func(_ context.Context, call *agentproto.Call) *agentproto.Result {
		return &agentproto.Result{ID: call.ID, IsError: true, Content: []byte(`[{"type":"text","text":"No battery found."}]`)}
	}
	e.connectMac()
	cs := e.client(stateful, nil)
	res := call(t, cs, "battery_status")
	l := waitTraced(t, ts, e.user.ID)[0]
	assert.True(t, l.IsError)
	assert.Equal(t, "error", l.Outcome)
	assert.JSONEq(t, contentJSON(t, res), string(l.Result))
	assert.Equal(t, `{}`, string(l.Arguments))
}

// A call to a machine that is offline never reached it: traced with the words Claude got.
func TestTraceOfAnOfflineCall(t *testing.T) {
	e, ts := setupTraced(t)
	e.pair()
	c := e.connectMac()
	require.NoError(t, c.Close())
	require.Eventually(t, func() bool { return !e.hub.Online(e.device.ID) }, 5*time.Second, 10*time.Millisecond)
	cs := e.client(stateful, nil)
	res := call(t, cs, "battery_status")
	l := waitTraced(t, ts, e.user.ID)[0]
	assert.Equal(t, "offline", l.Outcome)
	assert.True(t, l.IsError)
	assert.JSONEq(t, contentJSON(t, res), string(l.Result))
	assert.Contains(t, string(l.Result), "is offline")
	assert.Equal(t, "Sam's MacBook Pro", l.Machine, "the machine the call went to")
	assert.NotEmpty(t, l.CallID)
}

func TestTraceOfATimeout(t *testing.T) {
	e, ts := setupTraced(t)
	e.pair()
	slow := testagent.BatteryStatusTool()
	slow.Name = "slow"
	slow.Meta = mcp.Meta{agentproto.DeadlineMetaKey: float64(200)}
	e.agent.Tools = append(e.agent.Tools, slow)
	e.agent.Handler = func(context.Context, *agentproto.Call) *agentproto.Result { return nil }
	e.connectMac()
	cs := e.client(stateful, nil)
	require.Eventually(t, func() bool { return slices.Contains(toolNames(t, cs), "slow") }, 5*time.Second, 20*time.Millisecond)
	res := call(t, cs, "slow")
	l := waitTraced(t, ts, e.user.ID)[0]
	assert.Equal(t, "timeout", l.Outcome)
	assert.Equal(t, "slow", l.Tool)
	assert.JSONEq(t, contentJSON(t, res), string(l.Result))
	assert.GreaterOrEqual(t, l.DurationMS, int64(200))
}

func TestTraceOfARevokedMachine(t *testing.T) {
	e, ts := setupTraced(t)
	e.pair()
	e.agent.Handler = func(context.Context, *agentproto.Call) *agentproto.Result {
		_ = e.store.RevokeDevice(context.Background(), e.device.ID, time.Now())
		e.hub.Revoke(e.device.ID)
		return nil
	}
	e.connectMac()
	cs := e.client(stateful, nil)
	res := call(t, cs, "battery_status")
	l := waitTraced(t, ts, e.user.ID)[0]
	assert.Equal(t, "error", l.Outcome)
	assert.JSONEq(t, contentJSON(t, res), string(l.Result))
	assert.Contains(t, string(l.Result), "was disconnected from this account")
}

func TestTraceOfALostConnection(t *testing.T) {
	e, ts := setupTraced(t)
	e.pair()
	var conn *testagent.Conn
	ready := make(chan struct{})
	e.agent.Handler = func(context.Context, *agentproto.Call) *agentproto.Result {
		<-ready
		_ = conn.Close()
		return nil
	}
	conn = e.connectMac()
	close(ready)
	cs := e.client(stateful, nil)
	res := call(t, cs, "battery_status")
	l := waitTraced(t, ts, e.user.ID)[0]
	assert.Equal(t, "error", l.Outcome)
	assert.JSONEq(t, contentJSON(t, res), string(l.Result))
	assert.Contains(t, string(l.Result), "lost its connection")
}

// A call whose client went away is traced all the same, with what the relay answered.
func TestTraceOfACancelledCall(t *testing.T) {
	e, ts := setupTraced(t)
	e.pair()
	started := make(chan struct{})
	e.agent.Handler = func(ctx context.Context, _ *agentproto.Call) *agentproto.Result {
		close(started)
		<-ctx.Done()
		return nil
	}
	e.connectMac()
	cs := e.client(stateful, nil)
	cctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _ = cs.CallTool(cctx, &mcp.CallToolParams{Name: "battery_status", Arguments: map[string]any{"x": 1}})
	}()
	<-started
	cancel()
	<-done
	l := waitTraced(t, ts, e.user.ID)[0]
	assert.Equal(t, "error", l.Outcome)
	assert.Contains(t, string(l.Result), "The request was cancelled.")
	assert.JSONEq(t, `{"x":1}`, string(l.Arguments))
}

// A call the relay refuses (a machine that isn't one of the account's) reached no machine.
func TestTraceOfARefusedCall(t *testing.T) {
	e, ts := setupTraced(t)
	e.pair()
	e.connectMac()
	cs := e.client(stateful, nil)
	res, _ := callWith(t, cs, "battery_status", map[string]any{"machine": "Nobody's PC"})
	require.True(t, res.IsError)
	l := waitTraced(t, ts, e.user.ID)[0]
	assert.Equal(t, "error", l.Outcome)
	assert.Empty(t, l.Machine, "null: it reached no machine")
	assert.JSONEq(t, `{"machine":"Nobody's PC"}`, string(l.Arguments))
	assert.JSONEq(t, contentJSON(t, res), string(l.Result))
	assert.NotEmpty(t, l.CallID)
}

// The relay's own machines tool is traced too.
func TestTraceOfTheMachinesTool(t *testing.T) {
	e, ts := setupTraced(t)
	e.pair()
	e.connectMac()
	cs := e.client(stateful, nil)
	res, _ := callWith(t, cs, agentproto.RelayToolMachines, map[string]any{})
	l := waitTraced(t, ts, e.user.ID)[0]
	assert.Equal(t, agentproto.RelayToolMachines, l.Tool)
	assert.Equal(t, "ok", l.Outcome)
	assert.Empty(t, l.Machine)
	assert.Equal(t, "test-client", l.Client)
	assert.NotEmpty(t, l.CallID)
	assert.JSONEq(t, contentJSON(t, res), string(l.Result))
	assert.Contains(t, string(l.Result), "Sam's MacBook Pro")
}

// Without a trace store (nil), calls work as before.
func TestNoTraceStore(t *testing.T) {
	e := setup(t)
	e.pair()
	e.connectMac()
	cs := e.client(stateful, nil)
	res := call(t, cs, "battery_status")
	assert.False(t, res.IsError)
}

// The requirements this file's tests cite (docs/requirements/; script/process-check).
// Validates: FR-683

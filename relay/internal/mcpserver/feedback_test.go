package mcpserver_test

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/mcpserver"
	"github.com/tonimelisma/latchkey/relay/reports"
)

// fakeIntake keeps what relays send it, checking the proof of work as the intake does.
type fakeIntake struct {
	mu     sync.Mutex
	got    [][]byte
	status int
}

func (f *fakeIntake) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	nonce, _ := strconv.ParseUint(r.Header.Get("Latchkey-Work-Nonce"), 10, 64)
	if r.URL.Path != "/v1/reports" || !reports.Shaped(body) || !reports.Proven(body, r.Header.Get("Latchkey-Work-Hour"), nonce, 4) {
		http.Error(w, "bad", http.StatusBadRequest)
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.status != 0 {
		w.WriteHeader(f.status)
		return
	}
	f.got = append(f.got, body)
	w.WriteHeader(http.StatusAccepted)
}

func (f *fakeIntake) received() [][]byte {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([][]byte(nil), f.got...)
}

func sharingEnv(t *testing.T, blocked bool) (*env, *fakeIntake, string) {
	t.Helper()
	pub, priv, err := reports.GenerateKey()
	require.NoError(t, err)
	pk, err := reports.PublicKey(pub)
	require.NoError(t, err)
	intake := &fakeIntake{}
	srv := httptest.NewServer(intake)
	t.Cleanup(srv.Close)
	e := setupWith(t, mcpserver.Options{Reports: mcpserver.ReportsOptions{
		IntakeURL: srv.URL, DeveloperKey: pk, Blocked: blocked, Client: srv.Client(), WorkBits: 4,
	}})
	return e, intake, priv
}

// Spec 014 FR-1401, FR-1403, FR-1410 to FR-1414, end to end with a real MCP client: no feedback
// tool until the Mac says the Owner shares; then a report goes to the intake sealed, opens with
// the developer's key with the fields of FR-1412, and the relay keeps nothing readable.
func TestSharedReportsReachTheIntakeSealed(t *testing.T) {
	e, intake, priv := sharingEnv(t, false)
	go e.ms.SendReports(ctx(t))
	e.pair()
	mac := e.connectMac()
	cs := e.client(stateful, nil)
	assert.NotContains(t, toolNames(t, cs), "feedback", "FR-1401: not shared, no tool")

	share := true
	e.agent.State.ShareReports = &share
	require.NoError(t, mac.Send(ctx(t), &agentproto.StateUpdate{State: e.agent.State}))
	require.Eventually(t, func() bool { return strings.Contains(strings.Join(toolNames(t, cs), ","), "feedback") },
		5*time.Second, 20*time.Millisecond, "sharing on: the tool appears")

	res, err := cs.CallTool(ctx(t), &mcp.CallToolParams{Name: "feedback", Arguments: map[string]any{
		"summary": "Create filter ignored the click", "details": "browser_act click e56: same page",
	}})
	require.NoError(t, err)
	require.False(t, res.IsError, text(t, res))
	assert.Contains(t, text(t, res), "queued for Latchkey's developer")
	assert.NotContains(t, text(t, res), "e56", "FR-1416: the answer doesn't repeat the report")

	require.Eventually(t, func() bool { return len(intake.received()) == 1 }, 10*time.Second, 20*time.Millisecond)
	k, err := reports.PrivateKey(priv)
	require.NoError(t, err)
	r, err := reports.Open(k, intake.received()[0])
	require.NoError(t, err)
	assert.Equal(t, "Create filter ignored the click", r.Summary)
	assert.Equal(t, "browser_act click e56: same page", r.Details)
	assert.NotEmpty(t, r.Client)
	assert.Equal(t, 3, r.Format)
	assert.Contains(t, text(t, res), r.ID, "the report holds the id the tool gave Claude")
	assert.True(t, strings.HasPrefix(r.ID, "fb_"), r.ID)
	require.Len(t, r.Machines, 1, "none named: the online machine")
	assert.NotEmpty(t, r.Machines[0].Version+r.Machines[0].System, "its versions")
	assert.False(t, r.Machines[0].Named)
	assert.NotContains(t, r.Details+r.Summary+r.Client+r.Machines[0].System, e.user.Email, "FR-1412: no email address")

	// Claude names the machine involved: the report marks it named, and never holds its name.
	res, err = cs.CallTool(ctx(t), &mcp.CallToolParams{Name: "feedback", Arguments: map[string]any{
		"summary": "Shell answered late", "details": "shell_run: 31 s", "machines": []any{"sam's macbook pro"},
	}})
	require.NoError(t, err)
	require.False(t, res.IsError, text(t, res))
	require.Eventually(t, func() bool { return len(intake.received()) == 2 }, 10*time.Second, 20*time.Millisecond)
	r, err = reports.Open(k, intake.received()[1])
	require.NoError(t, err)
	require.Len(t, r.Machines, 1)
	assert.True(t, r.Machines[0].Named, "the machine Claude named")
	sealedJSON, err := json.Marshal(r)
	require.NoError(t, err)
	assert.NotContains(t, strings.ToLower(string(sealedJSON)), "macbook", "FR-1412: never a machine's name")

	// Delivered: nothing left in the outbox (removed right after the intake's answer).
	require.Eventually(t, func() bool {
		due, err := e.store.DueReports(context.Background(), time.Now().Add(time.Hour), 10)
		return err == nil && len(due) == 0
	}, 5*time.Second, 20*time.Millisecond)

	// Missing summary: told, nothing sent.
	res, err = cs.CallTool(ctx(t), &mcp.CallToolParams{Name: "feedback", Arguments: map[string]any{"summary": " ", "details": "x"}})
	require.NoError(t, err)
	assert.True(t, res.IsError)

	// Sharing off: the tool goes.
	off := false
	e.agent.State.ShareReports = &off
	require.NoError(t, mac.Send(ctx(t), &agentproto.StateUpdate{State: e.agent.State}))
	require.Eventually(t, func() bool { return !strings.Contains(strings.Join(toolNames(t, cs), ","), "feedback") },
		5*time.Second, 20*time.Millisecond, "sharing off: the tool is gone")
}

// FR-1414: a report the intake doesn't accept yet stays sealed in the outbox and is retried;
// FR-1403: turning sharing off drops it.
func TestAWaitingReportIsDroppedWhenSharingStops(t *testing.T) {
	e, intake, _ := sharingEnv(t, false)
	intake.status = http.StatusServiceUnavailable
	e.pair()
	share := true
	e.agent.State.ShareReports = &share
	mac := e.connectMac()
	cs := e.client(stateful, nil)
	require.Eventually(t, func() bool { return strings.Contains(strings.Join(toolNames(t, cs), ","), "feedback") },
		5*time.Second, 20*time.Millisecond)
	secret := "the words of this report"
	res, err := cs.CallTool(ctx(t), &mcp.CallToolParams{Name: "feedback", Arguments: map[string]any{"summary": "x", "details": secret}})
	require.NoError(t, err)
	require.False(t, res.IsError, text(t, res))
	go e.ms.SendReports(ctx(t))
	require.Eventually(t, func() bool {
		due, err := e.store.DueReports(context.Background(), time.Now().Add(48*time.Hour), 10)
		return err == nil && len(due) == 1 && due[0].Tries >= 1
	}, 10*time.Second, 20*time.Millisecond, "kept, tried once, due again later")
	due, _ := e.store.DueReports(context.Background(), time.Now().Add(48*time.Hour), 10)
	assert.NotContains(t, string(due[0].Sealed), secret, "the relay holds only sealed bytes")

	off := false
	e.agent.State.ShareReports = &off
	require.NoError(t, mac.Send(ctx(t), &agentproto.StateUpdate{State: e.agent.State}))
	require.Eventually(t, func() bool {
		due, err := e.store.DueReports(context.Background(), time.Now().Add(48*time.Hour), 10)
		return err == nil && len(due) == 0
	}, 5*time.Second, 20*time.Millisecond, "sharing off: waiting reports dropped")
}

// FR-1415a: with the operator's block, no tool, whatever the Owner chose.
func TestTheOperatorsBlockOffersNoTool(t *testing.T) {
	e, _, _ := sharingEnv(t, true)
	e.pair()
	share := true
	e.agent.State.ShareReports = &share
	e.connectMac()
	cs := e.client(stateful, nil)
	time.Sleep(200 * time.Millisecond)
	assert.NotContains(t, toolNames(t, cs), "feedback")
}

// FR-1406: while the Owner shares problem reports, an error answer ends with a reminder of the
// feedback tool; without sharing it doesn't (TestMacErrorResultPassesThrough).
func TestAnErrorRemindsClaudeOfFeedbackWhileSharing(t *testing.T) {
	e, _, _ := sharingEnv(t, false)
	e.pair()
	share := true
	e.agent.State.ShareReports = &share
	e.agent.Handler = func(_ context.Context, call *agentproto.Call) *agentproto.Result {
		return &agentproto.Result{ID: call.ID, IsError: true, Content: []byte(`[{"type":"text","text":"No battery found."}]`)}
	}
	e.connectMac()
	cs := e.client(stateful, nil)
	res := call(t, cs, "battery_status")
	require.True(t, res.IsError)
	last, _ := res.Content[len(res.Content)-1].(*mcp.TextContent)
	require.NotNil(t, last)
	assert.Contains(t, last.Text, "feedback tool")
}

// FR-1403 (security review 2026-11-23): the sender checks the Owner's choice again before each
// send; a report queued while sharing was on never leaves once it is off, even if the drop at
// the change was missed.
func TestTheSenderChecksSharingAgain(t *testing.T) {
	e, intake, _ := sharingEnv(t, false)
	e.pair()
	share := true
	e.agent.State.ShareReports = &share
	e.connectMac()
	cs := e.client(stateful, nil)
	require.Eventually(t, func() bool { return strings.Contains(strings.Join(toolNames(t, cs), ","), "feedback") },
		5*time.Second, 20*time.Millisecond)
	res, err := cs.CallTool(ctx(t), &mcp.CallToolParams{Name: "feedback", Arguments: map[string]any{"summary": "x", "details": "y"}})
	require.NoError(t, err)
	require.False(t, res.IsError, text(t, res))
	// The machine is removed (unpairing doesn't pass through the sharing change).
	require.NoError(t, e.store.RevokeDevice(context.Background(), e.device.ID, time.Now()))
	go e.ms.SendReports(ctx(t))
	require.Eventually(t, func() bool {
		due, err := e.store.DueReports(context.Background(), time.Now().Add(48*time.Hour), 10)
		return err == nil && len(due) == 0
	}, 5*time.Second, 20*time.Millisecond, "dropped by the sender")
	assert.Empty(t, intake.received(), "never sent")
}

// The requirements this file's tests cite (docs/requirements/; script/process-check).
// Validates: FR-1401, FR-1403, FR-1406, FR-1410, FR-1412, FR-1414, FR-1415a, FR-1416

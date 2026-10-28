package hub_test

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/events"
	"github.com/tonimelisma/latchkey/relay/internal/hub"
	"github.com/tonimelisma/latchkey/relay/internal/store"
	"github.com/tonimelisma/latchkey/relay/internal/testagent"
)

// syncBuffer is a log destination the hub's goroutines may write while the test reads.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func setupWithEvents(t *testing.T) (*env, *syncBuffer) {
	t.Helper()
	out := &syncBuffer{}
	var rec *events.Recorder
	e := setup(t, func(c *hub.Config) {
		// The store is opened inside setup; the recorder is attached right after, below.
		rec = events.New(nil, nil, nil)
		c.Events = rec
	})
	*rec = *events.New(e.store, slog.New(slog.NewTextHandler(out, nil)), nil)
	return e, out
}

func (e *env) events(kind string) []store.Event {
	e.t.Helper()
	all, err := e.store.Events(context.Background(), e.user.ID, 1000)
	require.NoError(e.t, err)
	var out []store.Event
	for _, ev := range all {
		if ev.Kind == kind {
			out = append(out, ev)
		}
	}
	return out
}

func (e *env) waitEvent(kind string, detail string) store.Event {
	e.t.Helper()
	var found store.Event
	require.Eventually(e.t, func() bool {
		for _, ev := range e.events(kind) {
			if strings.Contains(ev.Detail, detail) {
				found = ev
				return true
			}
		}
		return false
	}, 5*time.Second, 10*time.Millisecond, "event %s with %q", kind, detail)
	return found
}

// FR-632: the call the Mac gets carries an id unique for all time.
func TestCallIDsAreGlobal(t *testing.T) {
	e := setup(t, nil)
	c := e.dial()
	_, err := e.hub.Call(ctxT(t), e.device.ID, "battery_status", nil, time.Second, nil)
	require.NoError(t, err)
	call := <-c.Calls
	assert.Regexp(t, `^call_[0-9A-Z]{26}$`, call.ID)

	_, err = e.hub.CallWithID(ctxT(t), e.device.ID, "call_GIVEN0000000000000000000", "battery_status", nil, time.Second, nil)
	require.NoError(t, err)
	assert.Equal(t, "call_GIVEN0000000000000000000", (<-c.Calls).ID)
}

// FR-631: each connection and its end, with the close code, reason, and goodbye reason.
func TestConnectionEventsAreRecorded(t *testing.T) {
	e, out := setupWithEvents(t)
	e.agent.Features = []string{agentproto.FeatureAudit}
	c := e.dial()
	ev := e.waitEvent(events.MacConnected, "keep-awake on")
	assert.Equal(t, e.device.ID, ev.DeviceID)
	assert.Contains(t, out.String(), `msg="Mac connected"`)

	require.NoError(t, c.Send(ctxT(t), &agentproto.Goodbye{Reason: agentproto.ReasonUserQuit, State: e.agent.State}))
	require.NoError(t, c.Close())
	ev = e.waitEvent(events.MacDisconnected, "goodbye user_quit")
	assert.Contains(t, ev.Detail, "close 1000")
	assert.Contains(t, out.String(), `msg="Mac disconnected"`)

	// Replaced by a newer connection: the relay's own close code and reason.
	e.dial()
	e.dial()
	e.waitEvent(events.MacDisconnected, "close 4003: replaced by a newer connection")

	// A protocol violation.
	c3 := e.dial()
	require.NoError(t, c3.SendRaw(ctxT(t), websocket.MessageText, []byte(`{"type":"nonsense"}`)))
	e.waitEvent(events.MacDisconnected, "close 4005")
}

// FR-631: a refused handshake is counted, without letting a stranger add a row per attempt.
func TestRefusedHandshakesAreCounted(t *testing.T) {
	e, out := setupWithEvents(t)
	stranger := testagent.New(e.url, "dev_nobody")
	for range 5 {
		assert.Equal(t, agentproto.CloseAuthFailed, e.dialRejected(stranger))
	}
	var refused []store.Event
	require.Eventually(t, func() bool {
		var err error
		refused, err = e.store.Events(context.Background(), "", 10)
		require.NoError(t, err)
		return len(refused) == 1 && refused[0].Count == 5
	}, 5*time.Second, 10*time.Millisecond)
	assert.Equal(t, events.MacRefused, refused[0].Kind)
	assert.Equal(t, 1, strings.Count(out.String(), "event=mac_refused"))

	bad := *e.agent
	bad.BadSignature = true
	assert.Equal(t, agentproto.CloseAuthFailed, e.dialRejected(&bad))
	e.waitEvent(events.MacRefused, "authentication failed")
}

// FR-631: keep-awake changes, from state messages, only when the state changes.
func TestKeepAwakeChangesAreRecorded(t *testing.T) {
	e, out := setupWithEvents(t)
	e.agent.NoHeartbeat = true
	c := e.dial()
	e.waitEvent(events.MacConnected, "keep-awake on")
	s := e.agent.State
	s.KeepAwake = agentproto.KeepAwakeOffUser
	for range 3 { // the same state again changes nothing
		require.NoError(t, c.Send(ctxT(t), &agentproto.StateUpdate{State: s}))
	}
	s.KeepAwake = agentproto.KeepAwakeOn
	require.NoError(t, c.Send(ctxT(t), &agentproto.StateUpdate{State: s}))
	e.waitEvent(events.KeepAwake, "on (was off_user)")
	assert.Len(t, e.events(events.KeepAwake), 2)
	assert.Equal(t, "off_user (was on)", e.events(events.KeepAwake)[1].Detail)
	assert.Contains(t, out.String(), `msg="keep-awake changed"`)

	// A new connection with a state other than the last one known is a change too.
	require.NoError(t, c.Close())
	e.agent.State.KeepAwake = agentproto.KeepAwakeOffTooHot
	e.dial()
	e.waitEvent(events.KeepAwake, "off_too_hot (was on)")
}

// FR-631: Disconnect in the Mac app unpairs it.
func TestUnpairingFromTheMacIsRecorded(t *testing.T) {
	e, _ := setupWithEvents(t)
	c := e.dial()
	require.NoError(t, c.Send(ctxT(t), &agentproto.Goodbye{Reason: agentproto.ReasonUserDisconnected, State: e.agent.State}))
	e.waitEvent(events.MacUnpaired, "the Mac app")
}

func (e *env) audit(at time.Time, callID, outcome string) {
	e.t.Helper()
	require.NoError(e.t, e.store.AddAudit(context.Background(), store.AuditEntry{
		UserID: e.user.ID, DeviceID: e.device.ID, At: at, Tool: "shell_run", Outcome: outcome,
		Duration: 7 * time.Millisecond, CallID: callID,
	}))
}

func nextAudit(t *testing.T, c *testagent.Conn) *agentproto.Audit {
	t.Helper()
	select {
	case m := <-c.Audits:
		return m
	case <-time.After(5 * time.Second):
		t.Fatal("no audit message")
		return nil
	}
}

// FR-634: the relay answers audit_request with this Mac's audit, page by page.
func TestAuditRequestIsAnswered(t *testing.T) {
	e := setup(t, nil)
	t0 := time.Date(2026, 10, 27, 10, 0, 0, 0, time.UTC)
	e.audit(t0, "", store.OutcomeOK)
	e.audit(t0.Add(time.Second), "call_A", store.OutcomeOffline)
	e.audit(t0.Add(2*time.Second), "call_B", store.OutcomeTimeout)
	e.agent.Features = []string{agentproto.FeatureAudit}
	c := e.dial()

	require.NoError(t, c.Send(ctxT(t), &agentproto.AuditRequest{ID: "a1", Since: t0.UnixMilli(), Limit: 2}))
	page := nextAudit(t, c)
	assert.Equal(t, "a1", page.ID)
	require.Len(t, page.Entries, 2)
	assert.Equal(t, agentproto.AuditEntry{CallID: "", At: t0.UnixMilli(), Tool: "shell_run", Outcome: "ok", DurationMS: 7}, page.Entries[0])
	assert.Equal(t, "offline", page.Entries[1].Outcome)
	require.NotNil(t, page.NextSince)

	require.NoError(t, c.Send(ctxT(t), &agentproto.AuditRequest{ID: "a2", Since: *page.NextSince, Limit: 2}))
	page = nextAudit(t, c)
	require.Len(t, page.Entries, 1)
	assert.Equal(t, "call_B", page.Entries[0].CallID)
	assert.Nil(t, page.NextSince)

	// Invalid since or limit: an empty page.
	require.NoError(t, c.Send(ctxT(t), &agentproto.AuditRequest{ID: "a3", Since: -5, Limit: 2}))
	page = nextAudit(t, c)
	assert.Equal(t, "a3", page.ID)
	assert.Empty(t, page.Entries)
	assert.Nil(t, page.NextSince)
}

// An app that didn't announce the feature gets no audit, ever; asking without it is a protocol
// violation.
func TestAuditNeedsTheFeature(t *testing.T) {
	e := setup(t, nil)
	c := e.dial()
	require.NoError(t, c.Send(ctxT(t), &agentproto.AuditRequest{ID: "a1", Since: 0, Limit: 10}))
	code, _ := c.Wait(ctxT(t))
	assert.Equal(t, agentproto.CloseProtocolViolation, code)
}

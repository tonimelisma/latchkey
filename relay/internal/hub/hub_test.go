package hub_test

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/hub"
	"github.com/tonimelisma/latchkey/relay/internal/store"
	"github.com/tonimelisma/latchkey/relay/internal/testagent"
)

type env struct {
	t      *testing.T
	store  *store.Store
	hub    *hub.Hub
	url    string
	user   store.User
	device store.Device
	agent  *testagent.Agent

	mu           sync.Mutex
	toolsChanged []string // user IDs
}

func setup(t *testing.T, tweak func(*hub.Config)) *env {
	t.Helper()
	ctx := context.Background()
	st, err := store.Open(ctx, filepath.Join(t.TempDir(), "relay.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = st.Close() })

	e := &env{t: t, store: st}
	cfg := hub.Config{
		HandshakeTimeout:  2 * time.Second,
		HeartbeatInterval: time.Second,
		OfflineAfter:      2 * time.Second,
		PingInterval:      time.Hour,
		OnToolsChanged: func(userID string) {
			e.mu.Lock()
			defer e.mu.Unlock()
			e.toolsChanged = append(e.toolsChanged, userID)
		},
	}
	if tweak != nil {
		tweak(&cfg)
	}
	e.hub = hub.New(st, cfg)
	srv := httptest.NewServer(e.hub)
	t.Cleanup(srv.Close)
	e.url = "ws" + strings.TrimPrefix(srv.URL, "http")

	e.user, err = st.CreateUser(ctx, "owner@example.com", time.Now())
	require.NoError(t, err)
	e.agent = testagent.New(e.url, "")
	e.device, err = st.CreateDevice(ctx, store.NewDevice{UserID: e.user.ID, Name: "Mac", PublicKey: e.agent.PublicKeyDER()}, time.Now())
	require.NoError(t, err)
	e.agent.DeviceID = e.device.ID
	return e
}

func (e *env) dial() *testagent.Conn {
	e.t.Helper()
	c, err := e.agent.Dial(ctxT(e.t))
	require.NoError(e.t, err)
	e.t.Cleanup(func() { _ = c.Close() })
	return c
}

// dialRejected dials and returns the close code the relay used to reject the handshake.
func (e *env) dialRejected(a *testagent.Agent) int {
	e.t.Helper()
	_, err := a.Dial(ctxT(e.t))
	require.Error(e.t, err)
	return testagent.CloseCode(err)
}

func ctxT(t *testing.T) context.Context {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)
	return ctx
}

func (e *env) state() store.DeviceState {
	e.t.Helper()
	st, err := e.store.DeviceState(context.Background(), e.device.ID)
	require.NoError(e.t, err)
	return st
}

func (e *env) waitOnline(want bool) {
	e.t.Helper()
	require.Eventually(e.t, func() bool { return e.hub.Online(e.device.ID) == want }, 5*time.Second, 10*time.Millisecond)
}

func TestHandshake(t *testing.T) {
	e := setup(t, nil)
	c := e.dial()
	assert.Equal(t, 1, c.Welcome.HeartbeatIntervalS)
	e.waitOnline(true)

	st := e.state()
	assert.True(t, st.Online)
	assert.False(t, st.ConnectedAt.IsZero())
	var s agentproto.State
	require.NoError(t, json.Unmarshal(st.StateJSON, &s))
	assert.Equal(t, 82, s.BatteryPercent)
	var tools []*mcp.Tool
	require.NoError(t, json.Unmarshal(st.ToolsJSON, &tools))
	require.Len(t, tools, 1)
	assert.Equal(t, "battery_status", tools[0].Name)

	d, err := e.store.Device(context.Background(), e.device.ID)
	require.NoError(t, err)
	assert.Equal(t, "0.1.0-test", d.AppVersion)

	e.mu.Lock()
	assert.Contains(t, e.toolsChanged, e.user.ID)
	e.mu.Unlock()
}

func TestHandshakeRejections(t *testing.T) {
	e := setup(t, func(c *hub.Config) { c.HandshakeTimeout = 300 * time.Millisecond })

	bad := *e.agent
	bad.BadSignature = true
	assert.Equal(t, agentproto.CloseAuthFailed, e.dialRejected(&bad), "bad signature")

	unknown := *e.agent
	unknown.DeviceID = "dev_unknown"
	assert.Equal(t, agentproto.CloseAuthFailed, e.dialRejected(&unknown), "unknown device")

	silent := *e.agent
	silent.SkipHello = true
	assert.Equal(t, agentproto.CloseHandshakeTimeout, e.dialRejected(&silent), "no hello")

	noProto := *e.agent
	noProto.NoSubprotocol = true
	assert.Equal(t, agentproto.CloseUnsupportedVersion, e.dialRejected(&noProto), "no subprotocol")

	for name, raw := range map[string]string{
		"unknown type":   `{"type":"reboot"}`,
		"wrong type":     `{"type":"state","state":{}}`,
		"tool collision": `{"type":"hello","device_id":"` + e.device.ID + `","signature":"x","tools":[{"name":"laptop_status","inputSchema":{"type":"object"}}],"state":{}}`,
		"not json":       `hello`,
	} {
		a := *e.agent
		a.RawHello = []byte(raw)
		assert.Equal(t, agentproto.CloseProtocolViolation, e.dialRejected(&a), name)
	}

	require.NoError(t, e.store.RevokeDevice(context.Background(), e.device.ID, time.Now()))
	assert.Equal(t, agentproto.CloseAuthFailed, e.dialRejected(e.agent), "revoked device")
	assert.False(t, e.hub.Online(e.device.ID))
}

func TestProtocolViolationsAfterWelcome(t *testing.T) {
	cases := map[string]func(*testagent.Conn) error{
		"unknown type": func(c *testagent.Conn) error {
			return c.SendRaw(context.Background(), websocket.MessageText, []byte(`{"type":"reboot"}`))
		},
		"binary frame": func(c *testagent.Conn) error {
			return c.SendRaw(context.Background(), websocket.MessageBinary, []byte(`{"type":"state"}`))
		},
		"wrong direction": func(c *testagent.Conn) error {
			return c.Send(context.Background(), &agentproto.Call{ID: "x", Tool: "y", Arguments: []byte(`{}`)})
		},
		"tools collision": func(c *testagent.Conn) error {
			return c.SendRaw(context.Background(), websocket.MessageText,
				[]byte(`{"type":"tools","tools":[{"name":"laptop_status","inputSchema":{"type":"object"}}]}`))
		},
	}
	for name, send := range cases {
		t.Run(name, func(t *testing.T) {
			e := setup(t, nil)
			c := e.dial()
			require.NoError(t, send(c))
			code, err := c.Wait(ctxT(t))
			require.NoError(t, err)
			assert.Equal(t, agentproto.CloseProtocolViolation, code)
			e.waitOnline(false)
		})
	}
}

func TestOversizeFrame(t *testing.T) {
	e := setup(t, nil)
	c := e.dial()
	big := `{"type":"state","pad":"` + strings.Repeat("x", agentproto.MaxFrameBytes) + `"}`
	_ = c.SendRaw(context.Background(), websocket.MessageText, []byte(big))
	code, err := c.Wait(ctxT(t))
	require.NoError(t, err)
	assert.Equal(t, agentproto.CloseMessageTooBig, code)
}

func TestNewerConnectionReplacesOlder(t *testing.T) {
	e := setup(t, nil)
	first := e.dial()
	second := e.dial()
	code, err := first.Wait(ctxT(t))
	require.NoError(t, err)
	assert.Equal(t, agentproto.CloseReplaced, code)

	time.Sleep(100 * time.Millisecond)
	assert.True(t, e.hub.Online(e.device.ID), "the newer connection stays online")
	assert.True(t, e.state().Online)

	res, err := e.hub.Call(ctxT(t), e.device.ID, "battery_status", nil, time.Second, nil)
	require.NoError(t, err)
	assert.JSONEq(t, `{"battery_percent":82,"charging":false,"power_source":"battery","time_remaining_min":312}`, string(res.StructuredContent))
	_ = second
}

func TestSilentMacGoesOffline(t *testing.T) {
	e := setup(t, func(c *hub.Config) { c.OfflineAfter = 500 * time.Millisecond })
	e.agent.NoHeartbeat = true
	c := e.dial()
	e.waitOnline(true)
	connected := e.state()

	c.Freeze()
	start := time.Now()
	e.waitOnline(false)
	assert.Less(t, time.Since(start), 2*time.Second)

	st := e.state()
	assert.False(t, st.Online)
	assert.Empty(t, st.OfflineReason)
	assert.Equal(t, connected.LastSeenAt, st.LastSeenAt, "last seen stays at the last frame")
}

func TestHeartbeatsKeepItOnline(t *testing.T) {
	e := setup(t, func(c *hub.Config) {
		c.HeartbeatInterval = time.Second
		c.OfflineAfter = 1500 * time.Millisecond
	})
	e.dial()
	time.Sleep(3 * time.Second)
	assert.True(t, e.hub.Online(e.device.ID))
}

func TestStateUpdatesAreStored(t *testing.T) {
	e := setup(t, nil)
	c := e.dial()
	s := e.agent.State
	s.BatteryPercent = 55
	require.NoError(t, c.Send(context.Background(), &agentproto.StateUpdate{State: s}))
	require.Eventually(t, func() bool {
		var got agentproto.State
		_ = json.Unmarshal(e.state().StateJSON, &got)
		return got.BatteryPercent == 55
	}, 5*time.Second, 10*time.Millisecond)
}

func TestToolsUpdate(t *testing.T) {
	e := setup(t, nil)
	c := e.dial()
	e.mu.Lock()
	e.toolsChanged = nil
	e.mu.Unlock()
	require.NoError(t, c.Send(context.Background(), &agentproto.ToolsUpdate{Tools: []*mcp.Tool{}}))
	require.Eventually(t, func() bool {
		e.mu.Lock()
		defer e.mu.Unlock()
		return len(e.toolsChanged) > 0 && string(e.state().ToolsJSON) == `[]`
	}, 5*time.Second, 10*time.Millisecond)
}

func TestGoodbyeRecordsReason(t *testing.T) {
	e := setup(t, nil)
	c := e.dial()
	s := e.agent.State
	s.BatteryPercent = 14
	s.KeepAwake = agentproto.KeepAwakeOffLowBattery
	require.NoError(t, c.Send(context.Background(), &agentproto.Goodbye{Reason: agentproto.ReasonLowBattery, State: s}))
	require.NoError(t, c.Close())
	e.waitOnline(false)
	require.Eventually(t, func() bool { return !e.state().Online }, 5*time.Second, 10*time.Millisecond)
	st := e.state()
	assert.Equal(t, agentproto.ReasonLowBattery, st.OfflineReason)
	var got agentproto.State
	require.NoError(t, json.Unmarshal(st.StateJSON, &got))
	assert.Equal(t, 14, got.BatteryPercent)
}

func TestReconnectClearsOfflineReason(t *testing.T) {
	e := setup(t, nil)
	c := e.dial()
	require.NoError(t, c.Send(context.Background(), &agentproto.Goodbye{Reason: agentproto.ReasonSystemSleep, State: e.agent.State}))
	require.NoError(t, c.Close())
	require.Eventually(t, func() bool { return e.state().OfflineReason == agentproto.ReasonSystemSleep }, 5*time.Second, 10*time.Millisecond)
	e.dial()
	require.Eventually(t, func() bool { st := e.state(); return st.Online && st.OfflineReason == "" }, 5*time.Second, 10*time.Millisecond)
}

func TestGoodbyeUserDisconnectedRevokes(t *testing.T) {
	e := setup(t, nil)
	c := e.dial()
	require.NoError(t, c.Send(context.Background(), &agentproto.Goodbye{Reason: agentproto.ReasonUserDisconnected, State: e.agent.State}))
	code, err := c.Wait(ctxT(t))
	require.NoError(t, err)
	assert.Equal(t, agentproto.CloseRevoked, code)
	d, err := e.store.Device(context.Background(), e.device.ID)
	require.NoError(t, err)
	assert.False(t, d.RevokedAt.IsZero())
	assert.Equal(t, agentproto.CloseAuthFailed, e.dialRejected(e.agent))
}

func TestCalls(t *testing.T) {
	e := setup(t, nil)
	e.dial()

	res, err := e.hub.Call(ctxT(t), e.device.ID, "battery_status", json.RawMessage(`{}`), time.Second, nil)
	require.NoError(t, err)
	assert.False(t, res.IsError)
	assert.JSONEq(t, `[{"type":"text","text":"{\"battery_percent\":82,\"charging\":false,\"power_source\":\"battery\",\"time_remaining_min\":312}"}]`, string(res.Content))
}

func TestCallOffline(t *testing.T) {
	e := setup(t, nil)
	start := time.Now()
	_, err := e.hub.Call(ctxT(t), e.device.ID, "battery_status", nil, time.Second, nil)
	require.ErrorIs(t, err, hub.ErrOffline)
	assert.Less(t, time.Since(start), 100*time.Millisecond)
}

func TestCallDeadlineCancelsAndDropsLateResult(t *testing.T) {
	e := setup(t, nil)
	release := make(chan struct{})
	e.agent.Handler = func(_ context.Context, call *agentproto.Call) *agentproto.Result {
		if call.Tool == "slow" {
			<-release // ignores cancel: a late result
		}
		return &agentproto.Result{ID: call.ID, Content: []byte(`[{"type":"text","text":"` + call.Tool + `"}]`)}
	}
	c := e.dial()

	start := time.Now()
	_, err := e.hub.Call(ctxT(t), e.device.ID, "slow", nil, 300*time.Millisecond, nil)
	require.ErrorIs(t, err, hub.ErrTimeout)
	assert.Less(t, time.Since(start), time.Second)

	select {
	case cancel := <-c.Cancels:
		assert.Equal(t, agentproto.CancelDeadline, cancel.Reason)
	case <-time.After(2 * time.Second):
		t.Fatal("no cancel sent")
	}
	close(release) // the late result arrives and must be ignored

	res, err := e.hub.Call(ctxT(t), e.device.ID, "fast", nil, time.Second, nil)
	require.NoError(t, err)
	assert.Contains(t, string(res.Content), "fast")
	assert.True(t, e.hub.Online(e.device.ID), "a late result is not a protocol violation")
}

func TestCallClientCancelled(t *testing.T) {
	e := setup(t, nil)
	e.agent.Handler = func(context.Context, *agentproto.Call) *agentproto.Result { return nil }
	c := e.dial()
	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(100 * time.Millisecond); cancel() }()
	_, err := e.hub.Call(ctx, e.device.ID, "battery_status", nil, 5*time.Second, nil)
	require.ErrorIs(t, err, context.Canceled)
	select {
	case m := <-c.Cancels:
		assert.Equal(t, agentproto.CancelClientCancelled, m.Reason)
	case <-time.After(2 * time.Second):
		t.Fatal("no cancel sent")
	}
}

func TestConcurrentCalls(t *testing.T) {
	e := setup(t, nil)
	e.agent.Handler = func(_ context.Context, call *agentproto.Call) *agentproto.Result {
		var n int
		_ = json.Unmarshal(call.Arguments, &n)
		time.Sleep(time.Duration(20-n) * 5 * time.Millisecond)
		return &agentproto.Result{ID: call.ID, Content: call.Arguments}
	}
	e.dial()
	var wg sync.WaitGroup
	for i := range 20 {
		wg.Go(func() {
			arg, _ := json.Marshal(i)
			res, err := e.hub.Call(ctxT(t), e.device.ID, "echo", arg, 2*time.Second, nil)
			if assert.NoError(t, err) {
				assert.JSONEq(t, string(arg), string(res.Content))
			}
		})
	}
	wg.Wait()
}

func TestProgressIsForwarded(t *testing.T) {
	e := setup(t, nil)
	var c *testagent.Conn
	e.agent.Handler = func(_ context.Context, call *agentproto.Call) *agentproto.Result {
		_ = c.Send(context.Background(), &agentproto.Progress{ID: call.ID, Progress: 1, Message: "half"})
		time.Sleep(50 * time.Millisecond)
		return &agentproto.Result{ID: call.ID, Content: []byte(`[]`)}
	}
	c = e.dial()
	var got []*agentproto.Progress
	_, err := e.hub.Call(ctxT(t), e.device.ID, "x", nil, time.Second, func(p *agentproto.Progress) { got = append(got, p) })
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, "half", got[0].Message)
}

func TestRevokeDuringCall(t *testing.T) {
	e := setup(t, nil)
	e.agent.Handler = func(context.Context, *agentproto.Call) *agentproto.Result { return nil }
	c := e.dial()
	go func() {
		time.Sleep(100 * time.Millisecond)
		_ = e.store.RevokeDevice(context.Background(), e.device.ID, time.Now())
		e.hub.Revoke(e.device.ID)
	}()
	_, err := e.hub.Call(ctxT(t), e.device.ID, "x", nil, 5*time.Second, nil)
	require.ErrorIs(t, err, hub.ErrRevoked)
	code, err := c.Wait(ctxT(t))
	require.NoError(t, err)
	assert.Equal(t, agentproto.CloseRevoked, code)
}

func TestDisconnectDuringCall(t *testing.T) {
	e := setup(t, nil)
	var c *testagent.Conn
	e.agent.Handler = func(context.Context, *agentproto.Call) *agentproto.Result {
		_ = c.Close()
		return nil
	}
	c = e.dial()
	_, err := e.hub.Call(ctxT(t), e.device.ID, "x", nil, 5*time.Second, nil)
	require.ErrorIs(t, err, hub.ErrDisconnected)
}

func TestNoticesOnConnectAndLive(t *testing.T) {
	at := time.Date(2026, 10, 19, 18, 30, 0, 0, time.UTC)
	e := setup(t, func(c *hub.Config) {
		c.NoticesOnConnect = func(_ context.Context, _ store.Device, _ time.Time) []*agentproto.Notice {
			return []*agentproto.Notice{{Kind: agentproto.NoticeAccountRecovered, At: at}}
		}
	})
	c := e.dial()
	select {
	case n := <-c.Notices:
		assert.Equal(t, agentproto.NoticeAccountRecovered, n.Kind)
		assert.Equal(t, at, n.At)
	case <-time.After(2 * time.Second):
		t.Fatal("no notice on connect")
	}
	e.waitOnline(true)
	require.NoError(t, e.hub.SendNotice(ctxT(t), e.device.ID, &agentproto.Notice{Kind: agentproto.NoticeAccountRecovered, At: at}))
	select {
	case <-c.Notices:
	case <-time.After(2 * time.Second):
		t.Fatal("no live notice")
	}
	require.ErrorIs(t, e.hub.SendNotice(ctxT(t), "dev_other", &agentproto.Notice{}), hub.ErrOffline)
}

func TestShutdownMarksDevicesOffline(t *testing.T) {
	e := setup(t, nil)
	e.dial()
	e.waitOnline(true)
	e.hub.Close()
	e.waitOnline(false)
	require.Eventually(t, func() bool { return !e.state().Online }, 5*time.Second, 10*time.Millisecond)
}

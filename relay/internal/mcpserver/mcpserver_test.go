package mcpserver_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/auth"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/hub"
	"github.com/tonimelisma/latchkey/relay/internal/mcpserver"
	"github.com/tonimelisma/latchkey/relay/internal/store"
	"github.com/tonimelisma/latchkey/relay/internal/testagent"
)

const (
	stateful  = "2025-11-25"
	stateless = "2026-07-28"
)

type env struct {
	t      *testing.T
	store  *store.Store
	hub    *hub.Hub
	srv    *httptest.Server
	user   store.User
	device store.Device
	agent  *testagent.Agent
}

// setup runs the relay's hub and MCP server. Bearer tokens are "token-<user ID>"; the real
// OAuth verifier replaces this in M2.
func setup(t *testing.T) *env {
	t.Helper()
	ctx := context.Background()
	st, err := store.Open(ctx, filepath.Join(t.TempDir(), "relay.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = st.Close() })

	var ms *mcpserver.Server
	h := hub.New(st, hub.Config{
		HeartbeatInterval: time.Second, OfflineAfter: 3 * time.Second, PingInterval: time.Hour,
		OnToolsChanged: func(userID string) { ms.ToolsChanged(userID) },
	})
	ms = mcpserver.New(st, h, mcpserver.Options{})
	verifier := func(_ context.Context, token string, _ *http.Request) (*auth.TokenInfo, error) {
		userID, ok := strings.CutPrefix(token, "token-")
		if !ok {
			return nil, auth.ErrInvalidToken
		}
		return &auth.TokenInfo{UserID: userID, Expiration: time.Now().Add(time.Hour)}, nil
	}
	mux := http.NewServeMux()
	mux.Handle("/agent/v1", h)
	mux.Handle("/mcp", auth.RequireBearerToken(verifier, nil)(ms))
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	e := &env{t: t, store: st, hub: h, srv: srv}
	e.user, err = st.CreateUser(ctx, "owner@example.com", time.Now())
	require.NoError(t, err)
	return e
}

func (e *env) pair() {
	e.t.Helper()
	e.agent = testagent.New("ws"+strings.TrimPrefix(e.srv.URL, "http")+"/agent/v1", "")
	var err error
	e.device, err = e.store.CreateDevice(context.Background(),
		store.NewDevice{UserID: e.user.ID, Name: "Mac", PublicKey: e.agent.PublicKeyDER()}, time.Now())
	require.NoError(e.t, err)
	e.agent.DeviceID = e.device.ID
}

func (e *env) connectMac() *testagent.Conn {
	e.t.Helper()
	c, err := e.agent.Dial(ctx(e.t))
	require.NoError(e.t, err)
	e.t.Cleanup(func() { _ = c.Close() })
	require.Eventually(e.t, func() bool { return e.hub.Online(e.device.ID) }, 5*time.Second, 10*time.Millisecond)
	return c
}

type bearer struct{ token string }

func (b bearer) RoundTrip(r *http.Request) (*http.Response, error) {
	r = r.Clone(r.Context())
	r.Header.Set("Authorization", "Bearer "+b.token)
	return http.DefaultTransport.RoundTrip(r)
}

func (e *env) client(version string, opts *mcp.ClientOptions) *mcp.ClientSession {
	e.t.Helper()
	c := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "1"}, opts)
	cs, err := c.Connect(ctx(e.t), &mcp.StreamableClientTransport{
		Endpoint:   e.srv.URL + "/mcp",
		HTTPClient: &http.Client{Transport: bearer{"token-" + e.user.ID}},
		MaxRetries: -1,
	}, &mcp.ClientSessionOptions{ProtocolVersion: version})
	require.NoError(e.t, err)
	e.t.Cleanup(func() { _ = cs.Close() })
	return cs
}

func ctx(t *testing.T) context.Context {
	c, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	t.Cleanup(cancel)
	return c
}

func toolNames(t *testing.T, cs *mcp.ClientSession) []string {
	t.Helper()
	res, err := cs.ListTools(ctx(t), nil)
	require.NoError(t, err)
	var names []string
	for _, tool := range res.Tools {
		names = append(names, tool.Name)
	}
	return names
}

func call(t *testing.T, cs *mcp.ClientSession, name string) *mcp.CallToolResult {
	t.Helper()
	res, err := cs.CallTool(ctx(t), &mcp.CallToolParams{Name: name, Arguments: map[string]any{}})
	require.NoError(t, err, "Mac failures must be tool results, not protocol errors")
	return res
}

func text(t *testing.T, res *mcp.CallToolResult) string {
	t.Helper()
	require.Len(t, res.Content, 1)
	tc, ok := res.Content[0].(*mcp.TextContent)
	require.True(t, ok, "got %T", res.Content[0])
	return tc.Text
}

func structured(t *testing.T, res *mcp.CallToolResult) map[string]any {
	t.Helper()
	data, err := json.Marshal(res.StructuredContent)
	require.NoError(t, err)
	var m map[string]any
	require.NoError(t, json.Unmarshal(data, &m))
	return m
}

func TestBothProtocolVersions(t *testing.T) {
	for _, v := range []string{stateful, stateless} {
		t.Run(v, func(t *testing.T) {
			e := setup(t)
			cs := e.client(v, nil)
			assert.Equal(t, []string{"laptop_status"}, toolNames(t, cs))
			assert.Equal(t, v, cs.InitializeResult().ProtocolVersion)
		})
	}
}

func TestUnauthenticatedIsRejected(t *testing.T) {
	e := setup(t)
	req, err := http.NewRequestWithContext(ctx(t), http.MethodPost, e.srv.URL+"/mcp", strings.NewReader(`{}`))
	require.NoError(t, err)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	_ = resp.Body.Close()
	assert.Equal(t, http.StatusUnauthorized, resp.StatusCode)
}

func TestNeverPaired(t *testing.T) {
	e := setup(t)
	cs := e.client(stateful, nil)
	assert.Equal(t, []string{"laptop_status"}, toolNames(t, cs))
	res := call(t, cs, "laptop_status")
	assert.False(t, res.IsError)
	assert.Equal(t, "No Mac is connected to this account yet. Open the Latchkey app on your Mac and click Connect.", text(t, res))
	assert.Equal(t, map[string]any{"paired": false, "online": false, "last_seen": nil, "offline_reason": nil, "state": nil}, structured(t, res))
}

func TestOnline(t *testing.T) {
	for _, v := range []string{stateful, stateless} {
		t.Run(v, func(t *testing.T) {
			e := setup(t)
			e.pair()
			e.connectMac()
			cs := e.client(v, nil)
			assert.ElementsMatch(t, []string{"laptop_status", "battery_status"}, toolNames(t, cs))

			res := call(t, cs, "battery_status")
			assert.False(t, res.IsError)
			assert.Equal(t, map[string]any{"battery_percent": 82.0, "charging": false, "power_source": "battery", "time_remaining_min": 312.0}, structured(t, res))

			res = call(t, cs, "laptop_status")
			assert.False(t, res.IsError)
			assert.Equal(t, "Your Mac is online: 82% battery, on battery power. Keep-awake is on.", text(t, res))
			s := structured(t, res)
			assert.Equal(t, true, s["paired"])
			assert.Equal(t, true, s["online"])
			assert.NotNil(t, s["last_seen"])
			state, ok := s["state"].(map[string]any)
			require.True(t, ok)
			assert.InDelta(t, 82, state["battery_percent"], 0)
			assert.Equal(t, "on", state["keep_awake"])
		})
	}
}

func TestBatteryToolMatchesContract(t *testing.T) {
	e := setup(t)
	e.pair()
	e.connectMac()
	cs := e.client(stateful, nil)
	res, err := cs.ListTools(ctx(t), nil)
	require.NoError(t, err)
	for _, tool := range res.Tools {
		if tool.Name == "battery_status" {
			assert.Equal(t, "Battery status", tool.Title)
			assert.InDelta(t, 5000, tool.Meta[agentproto.DeadlineMetaKey], 0)
			assert.True(t, tool.Annotations.ReadOnlyHint)
			return
		}
	}
	t.Fatal("battery_status not listed")
}

func TestOffline(t *testing.T) {
	for _, v := range []string{stateful, stateless} {
		t.Run(v, func(t *testing.T) {
			e := setup(t)
			e.pair()
			c := e.connectMac()
			s := e.agent.State
			s.BatteryPercent = 14
			s.KeepAwake = agentproto.KeepAwakeOffLowBattery
			require.NoError(t, c.Send(ctx(t), &agentproto.Goodbye{Reason: agentproto.ReasonLowBattery, State: s}))
			require.NoError(t, c.Close())
			require.Eventually(t, func() bool { return !e.hub.Online(e.device.ID) }, 5*time.Second, 10*time.Millisecond)

			cs := e.client(v, nil)
			assert.ElementsMatch(t, []string{"laptop_status", "battery_status"}, toolNames(t, cs), "last reported tools stay listed (FR-013)")

			start := time.Now()
			res := call(t, cs, "battery_status")
			assert.Less(t, time.Since(start), time.Second, "SC-03")
			assert.True(t, res.IsError)
			assert.Regexp(t, `^Your Mac is offline\. It went to sleep for low battery at 14%, at \d{1,2}:\d\d [AP]M \(just now\)\.$`, text(t, res))

			res = call(t, cs, "laptop_status")
			assert.False(t, res.IsError, "laptop_status works offline")
			st := structured(t, res)
			assert.Equal(t, false, st["online"])
			assert.Equal(t, "low_battery", st["offline_reason"])
		})
	}
}

func TestDeadline(t *testing.T) {
	e := setup(t)
	e.pair()
	slow := testagent.BatteryStatusTool()
	slow.Name = "slow"
	slow.Meta = mcp.Meta{agentproto.DeadlineMetaKey: float64(300)}
	e.agent.Tools = append(e.agent.Tools, slow)
	e.agent.Handler = func(c context.Context, call *agentproto.Call) *agentproto.Result {
		if call.Tool == "slow" {
			return nil
		}
		return testagent.BatteryHandler(82)(c, call)
	}
	c := e.connectMac()
	cs := e.client(stateful, nil)

	start := time.Now()
	res := call(t, cs, "slow")
	assert.Less(t, time.Since(start), 2*time.Second)
	assert.True(t, res.IsError)
	assert.Equal(t, "Your Mac didn't answer within 0.3 seconds. It may be busy or losing its connection.", text(t, res))
	select {
	case m := <-c.Cancels:
		assert.Equal(t, agentproto.CancelDeadline, m.Reason)
	case <-time.After(2 * time.Second):
		t.Fatal("Mac not told to cancel")
	}
}

func TestRevokedDuringCall(t *testing.T) {
	e := setup(t)
	e.pair()
	e.agent.Handler = func(context.Context, *agentproto.Call) *agentproto.Result {
		_ = e.store.RevokeDevice(context.Background(), e.device.ID, time.Now())
		e.hub.Revoke(e.device.ID)
		return nil
	}
	e.connectMac()
	cs := e.client(stateful, nil)
	res := call(t, cs, "battery_status")
	assert.True(t, res.IsError)
	assert.Equal(t, "Your Mac was disconnected from this account while the request was running.", text(t, res))
	require.Eventually(t, func() bool {
		return len(toolNames(t, cs)) == 1
	}, 5*time.Second, 20*time.Millisecond, "a revoked Mac's tools disappear")
}

func TestToolListChanged(t *testing.T) {
	e := setup(t)
	e.pair()
	c := e.connectMac()
	var mu sync.Mutex
	notified := 0
	cs := e.client(stateful, &mcp.ClientOptions{
		ToolListChangedHandler: func(context.Context, *mcp.ToolListChangedRequest) {
			mu.Lock()
			notified++
			mu.Unlock()
		},
	})
	require.ElementsMatch(t, []string{"laptop_status", "battery_status"}, toolNames(t, cs))

	// The Owner turns System info off: its tool must vanish (FR-061, FR-062, SC-08).
	require.NoError(t, c.Send(ctx(t), &agentproto.ToolsUpdate{Tools: []*mcp.Tool{}}))
	require.Eventually(t, func() bool {
		mu.Lock()
		defer mu.Unlock()
		return notified > 0
	}, 5*time.Second, 10*time.Millisecond, "list_changed sent")
	assert.Equal(t, []string{"laptop_status"}, toolNames(t, cs))

	res, err := cs.CallTool(ctx(t), &mcp.CallToolParams{Name: "battery_status"})
	if err == nil {
		assert.True(t, res.IsError, "a disabled tool is not callable")
	}
}

func TestToolListIsPerUser(t *testing.T) {
	e := setup(t)
	e.pair()
	e.connectMac()
	other, err := e.store.CreateUser(context.Background(), "other@example.com", time.Now())
	require.NoError(t, err)
	mine := e.user
	e.user = other
	cs := e.client(stateful, nil)
	assert.Equal(t, []string{"laptop_status"}, toolNames(t, cs), "another user never sees my Mac's tools")
	e.user = mine
}

func TestAuditLog(t *testing.T) {
	e := setup(t)
	e.pair()
	c := e.connectMac()
	cs := e.client(stateful, nil)
	call(t, cs, "battery_status")
	call(t, cs, "laptop_status")
	require.NoError(t, c.Close())
	require.Eventually(t, func() bool { return !e.hub.Online(e.device.ID) }, 5*time.Second, 10*time.Millisecond)
	call(t, cs, "battery_status")

	entries, err := e.store.AuditForUser(context.Background(), e.user.ID, 10)
	require.NoError(t, err)
	require.Len(t, entries, 3)
	assert.Equal(t, "battery_status", entries[0].Tool)
	assert.Equal(t, store.OutcomeOffline, entries[0].Outcome)
	assert.Equal(t, "laptop_status", entries[1].Tool)
	assert.Equal(t, store.OutcomeOK, entries[1].Outcome)
	assert.Equal(t, store.OutcomeOK, entries[2].Outcome)
	assert.Equal(t, "test-client", entries[2].Surface)
	assert.Equal(t, e.device.ID, entries[2].DeviceID)
}

func TestMacErrorResultPassesThrough(t *testing.T) {
	e := setup(t)
	e.pair()
	e.agent.Handler = func(_ context.Context, call *agentproto.Call) *agentproto.Result {
		return &agentproto.Result{ID: call.ID, IsError: true, Content: []byte(`[{"type":"text","text":"No battery found."}]`)}
	}
	e.connectMac()
	cs := e.client(stateful, nil)
	res := call(t, cs, "battery_status")
	assert.True(t, res.IsError)
	assert.Equal(t, "No battery found.", text(t, res))
	entries, err := e.store.AuditForUser(context.Background(), e.user.ID, 1)
	require.NoError(t, err)
	assert.Equal(t, store.OutcomeError, entries[0].Outcome)
}

func TestMalformedMacResult(t *testing.T) {
	e := setup(t)
	e.pair()
	e.agent.Handler = func(_ context.Context, call *agentproto.Call) *agentproto.Result {
		return &agentproto.Result{ID: call.ID, Content: []byte(`{"not":"an array"}`)}
	}
	e.connectMac()
	cs := e.client(stateful, nil)
	res := call(t, cs, "battery_status")
	assert.True(t, res.IsError)
	assert.Contains(t, text(t, res), "couldn't read")
}

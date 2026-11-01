package mcpserver_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/store"
	"github.com/tonimelisma/latchkey/relay/internal/testagent"
)

func runTool(desc string) *mcp.Tool {
	return &mcp.Tool{
		Name: "shell_run", Title: "Run a Command", Description: desc,
		InputSchema: map[string]any{"type": "object", "properties": map[string]any{"command": map[string]any{"type": "string"}}},
		Meta:        mcp.Meta{agentproto.DeadlineMetaKey: 5000.0},
	}
}

// echo answers with who it is and the arguments it got.
func echo(who string) testagent.Handler {
	return func(_ context.Context, call *agentproto.Call) *agentproto.Result {
		content, _ := json.Marshal([]map[string]string{{"type": "text", "text": who + " ran " + call.Tool + " with " + string(call.Arguments)}})
		return &agentproto.Result{ID: call.ID, Content: content}
	}
}

// pairLinux pairs a pretend Linux server with the env's user.
func (e *env) pairLinux(name string) (*testagent.Agent, store.Device) {
	e.t.Helper()
	a := testagent.New("ws"+strings.TrimPrefix(e.srv.URL, "http")+"/agent/v1", "")
	a.Kind, a.OSVersion = agentproto.KindLinux, "Ubuntu 24.04.1 LTS"
	up := int64(3 * 24 * 3600)
	a.State = agentproto.State{PowerSource: "unknown", ThermalState: "nominal", KeepAwake: "on", UptimeS: &up, ObservedAt: time.Now().UTC()}
	d, err := e.store.CreateDevice(context.Background(),
		store.NewDevice{UserID: e.user.ID, Name: name, Kind: store.KindLinux, PublicKey: a.PublicKeyDER()}, time.Now())
	require.NoError(e.t, err)
	a.DeviceID = d.ID
	return a, d
}

func dialAgent(t *testing.T, e *env, a *testagent.Agent) *testagent.Conn {
	t.Helper()
	c, err := a.Dial(ctx(t))
	require.NoError(t, err)
	t.Cleanup(func() { _ = c.Close() })
	require.Eventually(t, func() bool { return e.hub.Online(a.DeviceID) }, 5*time.Second, 10*time.Millisecond)
	return c
}

func callWith(t *testing.T, cs *mcp.ClientSession, name string, args map[string]any) (*mcp.CallToolResult, string) {
	t.Helper()
	res, err := cs.CallTool(ctx(t), &mcp.CallToolParams{Name: name, Arguments: args})
	require.NoError(t, err)
	var b strings.Builder
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			b.WriteString(tc.Text)
		}
	}
	return res, b.String()
}

// A Mac and a Linux server behind one connector, through a real MCP client (spec 010 SC-1001,
// SC-1002, SC-1004).
func TestTwoMachinesBehindOneConnector(t *testing.T) {
	e := setup(t)
	e.pair()
	e.agent.Tools = []*mcp.Tool{testagent.BatteryStatusTool(), runTool("Runs a command on the Mac (zsh).")}
	e.agent.Handler = echo("the Mac")
	dialAgent(t, e, e.agent)
	server, serverDevice := e.pairLinux("homeserver")
	server.Tools = []*mcp.Tool{runTool("Runs a command on the server (bash).")}
	server.Handler = echo("the server")
	serverConn := dialAgent(t, e, server)

	cs := e.client(stateful, nil)
	assert.NotEmpty(t, cs.InitializeResult().Instructions, "the instructions name the machines tool")
	list, err := cs.ListTools(ctx(t), nil)
	require.NoError(t, err)
	byName := map[string]*mcp.Tool{}
	for _, tool := range list.Tools {
		byName[tool.Name] = tool
	}
	require.Len(t, byName, 3, "machines, battery_status, and shell_run once")
	assert.Equal(t, "On a Mac: Runs a command on the Mac (zsh).\n\nOn a Linux server: Runs a command on the server (bash).", byName["shell_run"].Description)
	schema, _ := json.Marshal(byName["shell_run"].InputSchema)
	assert.Contains(t, string(schema), `"machine"`)

	// Claude finds out what's there.
	_, text := callWith(t, cs, "machines", map[string]any{})
	assert.Contains(t, text, "- Toni's MacBook Pro · Mac (macOS 26.1) · online")
	assert.Contains(t, text, "- homeserver · Linux server (Ubuntu 24.04.1 LTS) · online · up 3 days · offers: shell_run")

	// Two machines offer shell_run: no guess.
	res, text := callWith(t, cs, "shell_run", map[string]any{"command": "df -h"})
	assert.True(t, res.IsError)
	assert.Equal(t, "Several machines offer shell_run: Toni's MacBook Pro (Mac, online), homeserver (Linux, online). Name one with machine.", text)

	// Named: it runs there, without the machine argument, and says where it ran.
	res, text = callWith(t, cs, "shell_run", map[string]any{"command": "df -h", "machine": "homeserver"})
	assert.False(t, res.IsError)
	assert.Equal(t, `the server ran shell_run with {"command":"df -h"}`+"\nhomeserver (Linux): online · up 3 days\nOther machines: Toni's MacBook Pro (Mac, online)", text)

	// Only the Mac offers battery_status: no name needed.
	_, text = callWith(t, cs, "battery_status", map[string]any{})
	assert.True(t, strings.HasPrefix(text, "the Mac ran battery_status"), text)
	assert.Contains(t, text, "\nToni's MacBook Pro (Mac): online · ")
	assert.Contains(t, text, "\nOther machines: homeserver (Linux, online)")

	// A machine without the tool: as if it didn't exist there.
	res, text = callWith(t, cs, "battery_status", map[string]any{"machine": "homeserver"})
	assert.True(t, res.IsError)
	assert.Equal(t, "homeserver doesn't offer battery_status. It's offered by: Toni's MacBook Pro (Mac, online).", text)

	// The server goes offline: named, it answers at once; unnamed, the Mac (the only one online) runs it.
	require.NoError(t, serverConn.Close())
	require.Eventually(t, func() bool { return !e.hub.Online(serverDevice.ID) }, 5*time.Second, 10*time.Millisecond)
	start := time.Now()
	res, text = callWith(t, cs, "shell_run", map[string]any{"command": "uptime", "machine": "homeserver"})
	assert.Less(t, time.Since(start), time.Second, "offline is answered at once (SC-1002)")
	assert.True(t, res.IsError)
	assert.True(t, strings.HasPrefix(text, "homeserver is offline."), text)
	assert.Contains(t, text, "Other machines: Toni's MacBook Pro (Mac, online)")
	_, text = callWith(t, cs, "shell_run", map[string]any{"command": "uptime"})
	assert.True(t, strings.HasPrefix(text, "the Mac ran shell_run"), text)

	// Unknown name.
	res, text = callWith(t, cs, "shell_run", map[string]any{"command": "uptime", "machine": "pi"})
	assert.True(t, res.IsError)
	assert.True(t, strings.HasPrefix(text, `No machine is called "pi". Your machines: Toni's MacBook Pro (Mac, online), homeserver (Linux, offline`), text)
}

// The machine's own name for itself, sent in hello, is kept unique and returned in welcome (spec
// 010 FR-1002); a hello of the wrong kind for the pairing is refused.
func TestMachineNameAndKindFromHello(t *testing.T) {
	e := setup(t)
	e.pair()
	server, d := e.pairLinux("homeserver")
	server.Name = "toni's macbook pro" // taken, whatever the case
	c := dialAgent(t, e, server)
	require.NotNil(t, c.Welcome)
	assert.Equal(t, "toni's macbook pro 2", c.Welcome.Name)
	got, err := e.store.Device(context.Background(), d.ID)
	require.NoError(t, err)
	assert.Equal(t, "toni's macbook pro 2", got.Name)
	require.NoError(t, c.Close())
	require.Eventually(t, func() bool { return !e.hub.Online(d.ID) }, 5*time.Second, 10*time.Millisecond)

	server.Name = "  nas\x00  "
	c = dialAgent(t, e, server)
	assert.Equal(t, "nas", c.Welcome.Name, "cleaned")

	// Only a Mac lists and removes Claude apps: a server asking to remove one is refused
	// (security review, 2026-10-31).
	require.NoError(t, c.Send(ctx(t), &agentproto.RevokeClient{ID: "grt_x"}))
	code, _ := c.Wait(ctx(t))
	assert.Equal(t, agentproto.CloseProtocolViolation, code)

	// The Mac's pairing, a Linux hello: refused.
	e.agent.Kind = agentproto.KindLinux
	mc, err := e.agent.Dial(ctx(t))
	if err == nil {
		code, _ := mc.Wait(ctx(t))
		assert.Equal(t, agentproto.CloseProtocolViolation, code)
	}
	assert.False(t, e.hub.Online(e.device.ID))
}

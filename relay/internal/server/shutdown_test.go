package server

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/testagent"
)

// Problem report of 2026-11-27: the hosted relay restarted (new settings applied) while a
// shell_run was running on the Mac, and the call failed with "lost its connection while the
// request was running", because the relay dropped its Macs before it stopped taking requests.
// A restart stops taking new requests first, lets the running calls be answered, and only then
// disconnects the Macs (spec 001 FR-095a).
func TestShutdownLetsRunningCallsFinish(t *testing.T) {
	h := newHarness(t, nil)
	o := h.owner("owner@example.com")
	a := o.mac()
	started := make(chan struct{})
	battery := testagent.BatteryHandler(82)
	a.Handler = func(ctx context.Context, call *agentproto.Call) *agentproto.Result {
		close(started)
		time.Sleep(400 * time.Millisecond) // the call is still running when the relay is told to stop
		return battery(ctx, call)
	}
	h.dial(a)
	client := h.registerClient(claudeCallback)
	access, _ := o.approve(client, claudeCallback)
	c := mcp.NewClient(&mcp.Implementation{Name: "claude-ai", Version: "1"}, nil)
	cs, err := c.Connect(tctx(t), &mcp.StreamableClientTransport{
		Endpoint: h.base + "/mcp", HTTPClient: &http.Client{Transport: bearerTransport{access}}, MaxRetries: -1,
	}, &mcp.ClientSessionOptions{ProtocolVersion: "2026-07-28"})
	require.NoError(t, err)
	t.Cleanup(func() { _ = cs.Close() })

	type answer struct {
		res *mcp.CallToolResult
		err error
	}
	got := make(chan answer, 1)
	go func() {
		res, err := cs.CallTool(tctx(t), &mcp.CallToolParams{Name: "battery_status", Arguments: map[string]any{}})
		got <- answer{res, err}
	}()
	<-started
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	require.NoError(t, h.relay.Shutdown(ctx, h.srv.Config))
	ans := <-got
	require.NoError(t, ans.err)
	assert.False(t, ans.res.IsError, "the running call got the Mac's answer: %v", ans.res.Content)
	assert.False(t, h.relay.Hub.Online(a.DeviceID), "the Macs are disconnected at the end")
}

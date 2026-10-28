package mcpserver_test

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/mcpserver"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

// FR-632: the id the Mac gets is the id in the audit, for every outcome, and never repeats.
func TestAuditCarriesTheCallID(t *testing.T) {
	e := setup(t)
	e.pair()
	c := e.connectMac()
	cs := e.client(stateful, nil)
	call(t, cs, "battery_status")
	sent := <-c.Calls

	entries, err := e.store.AuditForUser(context.Background(), e.user.ID, 10)
	require.NoError(t, err)
	require.Len(t, entries, 1)
	assert.Equal(t, sent.ID, entries[0].CallID)
	// FR-637: the call names the Claude app exactly as the audit does.
	assert.Equal(t, "test-client", sent.Client)
	assert.Equal(t, entries[0].Surface, sent.Client)

	require.NoError(t, c.Close())
	require.Eventually(t, func() bool { return !e.hub.Online(e.device.ID) }, 5*time.Second, 10*time.Millisecond)
	call(t, cs, "battery_status") // offline: never reached the Mac, recorded all the same
	entries, err = e.store.AuditForUser(context.Background(), e.user.ID, 10)
	require.NoError(t, err)
	require.Len(t, entries, 2)
	assert.Equal(t, store.OutcomeOffline, entries[0].Outcome)
	assert.True(t, strings.HasPrefix(entries[0].CallID, "call_"))
	assert.NotEqual(t, entries[0].CallID, entries[1].CallID)
}

// A call whose client goes away is audited too: the write doesn't share the request's end.
func TestCancelledCallIsAudited(t *testing.T) {
	e := setup(t)
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
		_, _ = cs.CallTool(cctx, &mcp.CallToolParams{Name: "battery_status"})
	}()
	<-started
	cancel()
	<-done
	require.Eventually(t, func() bool {
		entries, err := e.store.AuditForUser(context.Background(), e.user.ID, 10)
		return err == nil && len(entries) == 1 && entries[0].Outcome == store.OutcomeError && entries[0].CallID != ""
	}, 5*time.Second, 10*time.Millisecond)
}

// FR-635: no line per request from the MCP SDK; its warnings and errors still come through.
func TestNoLinePerRequest(t *testing.T) {
	out := &lockedBuffer{}
	e := setupWith(t, mcpserver.Options{Logger: slog.New(slog.NewTextHandler(out, &slog.HandlerOptions{Level: slog.LevelDebug}))})
	e.pair()
	e.connectMac()
	for range 3 {
		cs := e.client(stateful, nil)
		call(t, cs, "battery_status")
		require.NoError(t, cs.Close())
	}
	sl := e.client(stateless, nil)
	call(t, sl, "battery_status")
	assert.NotContains(t, out.String(), "session connected")
	assert.NotContains(t, out.String(), "server connecting")
	assert.NotContains(t, out.String(), "level=INFO", out.String())
	assert.NotContains(t, out.String(), "level=DEBUG", out.String())
}

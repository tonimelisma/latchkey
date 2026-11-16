package mcpserver

import (
	"bytes"
	"context"
	"encoding/json"
	"path/filepath"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/hub"
	"github.com/tonimelisma/latchkey/relay/internal/store"
	"github.com/tonimelisma/latchkey/relay/internal/trace"
)

// A call that finds no machine at all (the last one was removed while Claude still listed its
// tools) is traced with what Claude got, and no machine.
func TestTraceOfACallWithNoMachines(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(ctx, filepath.Join(t.TempDir(), "relay.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = st.Close() })
	u, err := st.CreateUser(ctx, "owner@example.com", time.Now())
	require.NoError(t, err)
	ts, err := trace.New(trace.Options{
		Dir: filepath.Join(t.TempDir(), "traces"), Key: bytes.Repeat([]byte{5}, 32),
		FreeSpace: func(string) (uint64, error) { return 100 << 30, nil },
	})
	require.NoError(t, err)
	s := New(st, hub.New(st, hub.Config{}), Options{Traces: ts})

	for _, h := range []mcp.ToolHandler{s.forward(u.ID, "battery_status"), s.listMachines(u.ID)} {
		res, err := h(ctx, &mcp.CallToolRequest{Params: &mcp.CallToolParamsRaw{Name: "battery_status", Arguments: json.RawMessage(`{"a": 1}`)}})
		require.NoError(t, err)
		require.True(t, res.IsError)
	}
	var got []trace.Line
	_, err = ts.Each(u.ID, "", "", func(l trace.Line) error {
		got = append(got, l)
		return nil
	})
	require.NoError(t, err)
	require.Len(t, got, 2)
	assert.Equal(t, "offline", got[0].Outcome)
	assert.Equal(t, "battery_status", got[0].Tool)
	assert.JSONEq(t, `{"a":1}`, string(got[0].Arguments))
	assert.JSONEq(t, `[{"type":"text","text":`+string(trace.String(neverPairedText))+`}]`, string(got[0].Result))
	assert.Empty(t, got[0].Machine)
	assert.Empty(t, got[0].Client, "null: no Claude app named itself")
	assert.Equal(t, "machines", got[1].Tool)
	assert.Equal(t, "error", got[1].Outcome)
}

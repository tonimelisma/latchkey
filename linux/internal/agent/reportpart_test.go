package agent

import (
	"encoding/json"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/linux/internal/activity"
	"github.com/tonimelisma/latchkey/relay/agentproto"
)

// Spec 014 FR-1444: this server's part holds the span's public log lines (never a private one)
// and its own copy of the chat's calls (never another chat's).
func TestReportPartHoldsTheSpansLogAndTheChatsCalls(t *testing.T) {
	dir := t.TempDir()
	log, err := activity.Open(activity.Files{Dir: filepath.Join(dir, "activity"), Old: filepath.Join(dir, "activity.jsonl")})
	require.NoError(t, err)
	start := time.Now().Add(-time.Minute)
	log.Event("connection", "Connected to the relay")
	log.Private("connection", false, "Connected to relay.example.net", "")
	require.NoError(t, log.Add(activity.Entry{
		Kind: "call", CallID: "call_A", Tool: "shell_run",
		Result: json.RawMessage(`[{"type":"text","text":"exit 0"}]`),
	}))
	require.NoError(t, log.Add(activity.Entry{
		Kind: "call", CallID: "call_OTHER", Tool: "files_read",
		Result: json.RawMessage(`[{"type":"text","text":"another chat"}]`),
	}))
	a := &Agent{Log: log}
	args, _ := json.Marshal(agentproto.ReportPartArgs{
		Since: start.UnixMilli(), Until: time.Now().Add(time.Minute).UnixMilli(),
		CallIDs: []string{"call_A"}, MaxBytes: 100_000,
	})
	res := a.reportPart(args)
	require.False(t, res.IsError, "%v", res.Content)
	var part agentproto.ReportPart
	require.NoError(t, json.Unmarshal([]byte(res.Content[0]["text"].(string)), &part))
	require.Len(t, part.Calls, 1)
	assert.Equal(t, "call_A", part.Calls[0].CallID)
	assert.Contains(t, string(part.Calls[0].Result), "exit 0")
	require.Len(t, part.Log, 1, "only the public line: %+v", part.Log)
	assert.Equal(t, "Connected to the relay", part.Log[0].Text)
	text := res.Content[0]["text"].(string)
	assert.NotContains(t, text, "relay.example.net")
	assert.NotContains(t, text, "another chat")

	args, _ = json.Marshal(agentproto.ReportPartArgs{
		Since: start.UnixMilli(), Until: time.Now().Add(time.Minute).UnixMilli(),
		CallIDs: []string{"call_A"}, MaxBytes: 150,
	})
	res = a.reportPart(args)
	require.False(t, res.IsError, "%v", res.Content)
	assert.LessOrEqual(t, len(res.Content[0]["text"].(string)), 150, "made to fit")
}

// The requirements this file's tests cite (docs/requirements/; script/process-check).
// Validates: FR-1444

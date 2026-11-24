package mcpserver_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// allTextD joins a result's text blocks, whatever lines the relay adds after the answer.
func allTextD(res *mcp.CallToolResult) string {
	var parts []string
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			parts = append(parts, tc.Text)
		}
	}
	return strings.Join(parts, "\n")
}

// Regression case regressions.feedback_tool_offered (2026-11-16, spec 014): every agent must be
// able to report what didn't work, also while no machine is online. With the Owner's Mac
// sharing problem reports and then gone offline, the feedback tool is still listed, and a call
// with an empty summary is refused asking for one, with nothing queued for the intake.
func TestRegressionDFeedbackWhileNoMachineIsOnline(t *testing.T) {
	e, intake, _ := sharingEnv(t, false)
	go e.ms.SendReports(ctx(t))
	e.pair()
	share := true
	e.agent.State.ShareReports = &share
	mac := e.connectMac()
	cs := e.client(stateful, nil)
	require.Eventually(t, func() bool { return strings.Contains(strings.Join(toolNames(t, cs), ","), "feedback") },
		10*time.Second, 20*time.Millisecond, "sharing on: the tool is there")

	require.NoError(t, mac.Close())
	require.Eventually(t, func() bool { return !e.hub.Online(e.device.ID) }, 10*time.Second, 10*time.Millisecond)
	assert.Contains(t, toolNames(t, cs), "feedback", "no machine online: the tool is still offered")

	res, err := cs.CallTool(ctx(t), &mcp.CallToolParams{Name: "feedback", Arguments: map[string]any{"summary": "", "details": "check"}})
	require.NoError(t, err)
	assert.True(t, res.IsError, allTextD(res))
	assert.Contains(t, allTextD(res), "Give a summary", "refused asking for a summary")
	due, err := e.store.DueReports(context.Background(), time.Now().Add(48*time.Hour), 10)
	require.NoError(t, err)
	assert.Empty(t, due, "nothing queued")

	// A report with a summary still goes, sealed, while the Mac is offline (regressions.
	// feedback_reaches_the_developer: the answer says so without repeating the report).
	res, err = cs.CallTool(ctx(t), &mcp.CallToolParams{Name: "feedback", Arguments: map[string]any{
		"summary": "Latchkey check: test report, please delete", "details": "A check of the report path; nothing failed.",
	}})
	require.NoError(t, err)
	require.False(t, res.IsError, allTextD(res))
	assert.Contains(t, allTextD(res), "encrypted and queued for Latchkey's developer")
	assert.NotContains(t, allTextD(res), "nothing failed", "the answer doesn't repeat the report")
	require.Eventually(t, func() bool { return len(intake.received()) == 1 }, 10*time.Second, 20*time.Millisecond)
	assert.NotContains(t, string(intake.received()[0]), "nothing failed", "only sealed bytes leave the relay")
}

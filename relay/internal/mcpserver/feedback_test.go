package mcpserver_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/agentproto"
)

// Spec 001 FR-690 to FR-692, end to end with a real MCP client: a report filed while the Mac is
// offline reaches it after its next welcome; one filed while it is online reaches it at once; a
// report the Mac saved is never sent again; a Mac without the feature never gets one.
func TestFeedbackReachesTheMacUntilItSavesIt(t *testing.T) {
	e := setup(t)
	e.pair()
	e.agent.Features = []string{agentproto.FeatureClients, agentproto.FeatureAudit, agentproto.FeatureFeedback}
	first := e.connectMac()
	cs := e.client(stateful, nil)
	require.NoError(t, first.Close())
	require.Eventually(t, func() bool { return !e.hub.Online(e.device.ID) }, 5*time.Second, 10*time.Millisecond)

	file := func(summary, details string) string {
		res, err := cs.CallTool(ctx(t), &mcp.CallToolParams{Name: "feedback", Arguments: map[string]any{
			"summary": summary, "details": details, "machine": "Toni's MacBook Pro",
		}})
		require.NoError(t, err)
		require.False(t, res.IsError, text(t, res))
		return text(t, res)
	}
	answer := file("Create filter ignored the click", "browser_act click e56: same page")
	assert.Contains(t, answer, "kept for the owner")

	// Missing summary: told, nothing kept.
	res, err := cs.CallTool(ctx(t), &mcp.CallToolParams{Name: "feedback", Arguments: map[string]any{"summary": " ", "details": "x"}})
	require.NoError(t, err)
	assert.True(t, res.IsError)

	mac := e.connectMac()
	got := receive(t, mac.Feedback)
	require.Len(t, got.Reports, 1)
	r := got.Reports[0]
	assert.Equal(t, "Create filter ignored the click", r.Summary)
	assert.Equal(t, "browser_act click e56: same page", r.Details)
	assert.Equal(t, "Toni's MacBook Pro", r.Machine)
	assert.NotEmpty(t, r.Client)
	assert.True(t, strings.HasPrefix(r.ID, "fb_"))

	// Filed while online: sent at once (with the one not yet saved).
	file("second", "")
	got = receive(t, mac.Feedback)
	require.Len(t, got.Reports, 2)
	require.NoError(t, mac.Send(ctx(t), &agentproto.FeedbackSaved{IDs: []string{got.Reports[0].ID, got.Reports[1].ID}}))
	require.Eventually(t, func() bool {
		w, err := e.store.WaitingFeedback(context.Background(), e.user.ID, 50)
		return err == nil && len(w) == 0
	}, 5*time.Second, 10*time.Millisecond)

	// Saved reports never come again.
	require.NoError(t, mac.Close())
	require.Eventually(t, func() bool { return !e.hub.Online(e.device.ID) }, 5*time.Second, 10*time.Millisecond)
	again := e.connectMac()
	select {
	case m := <-again.Feedback:
		t.Fatalf("saved reports sent again: %v", m.Reports)
	case <-time.After(300 * time.Millisecond):
	}

	// A Mac without the feature gets nothing and stays connected.
	require.NoError(t, again.Close())
	require.Eventually(t, func() bool { return !e.hub.Online(e.device.ID) }, 5*time.Second, 10*time.Millisecond)
	e.agent.Features = []string{agentproto.FeatureClients}
	old := e.connectMac()
	file("third", "")
	time.Sleep(200 * time.Millisecond)
	assert.True(t, e.hub.Online(e.device.ID), "an app without the feature isn't sent a message it doesn't know")
	_ = old
}

func receive[T any](t *testing.T, ch chan T) T {
	t.Helper()
	select {
	case m := <-ch:
		return m
	case <-time.After(5 * time.Second):
		var zero T
		t.Fatal("nothing received")
		return zero
	}
}

package agent

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/linux/internal/activity"
	"github.com/tonimelisma/latchkey/linux/internal/config"
	"github.com/tonimelisma/latchkey/relay/agentproto"
)

// Regression case regressions.machines_audit_all_match (2026-11-04, linux 0.1.2): the relay
// times a call as it sends it, a moment before the server logs it. The audit check asked the
// relay from the log's first call exactly, the relay (which answers only entries from since on)
// left that call out, and every check named it missing. The whole check runs here against a
// relay stand-in on localhost that answers like the real one.
func TestRegressionDAuditCountsTheLogsFirstCall(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	p := config.PathsFor(t.TempDir(), "", "", "")
	log, err := activity.Open(activity.Files{Dir: p.Activity, Old: p.ActivityV0})
	require.NoError(t, err)
	first := time.Now().Add(-2 * time.Hour).UTC().Truncate(time.Millisecond)
	require.NoError(t, log.Add(activity.Entry{Kind: "call", CallID: "call_first", Tool: "shell_run", At: first}))
	require.NoError(t, log.Add(activity.Entry{Kind: "call", CallID: "call_later", Tool: "shell_run", At: first.Add(time.Hour)}))

	relay := []agentproto.AuditEntry{
		{CallID: "call_before_the_log", At: first.Add(-5 * time.Minute).UnixMilli(), Tool: "shell_run", Outcome: "ok"},
		{CallID: "call_first", At: first.Add(-150 * time.Millisecond).UnixMilli(), Tool: "shell_run", Outcome: "ok"},
		{CallID: "call_later", At: first.Add(time.Hour).UnixMilli(), Tool: "shell_run", Outcome: "ok"},
	}
	answers := make(chan *agentproto.Audit, 4)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer ws.CloseNow() //nolint:errcheck // the test's end
		for {
			_, data, err := ws.Read(r.Context())
			if err != nil {
				return
			}
			m, err := agentproto.Decode(data)
			if err != nil {
				continue
			}
			req, ok := m.(*agentproto.AuditRequest)
			if !ok {
				continue
			}
			// Like the relay: only entries from since on, one page.
			page := &agentproto.Audit{ID: req.ID, Entries: []agentproto.AuditEntry{}}
			for _, e := range relay {
				if e.At >= req.Since {
					page.Entries = append(page.Entries, e)
				}
			}
			answers <- page
		}
	}))
	defer srv.Close()

	ws, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(srv.URL, "http"), nil)
	require.NoError(t, err)
	defer ws.CloseNow() //nolint:errcheck // the test's end

	a := &Agent{Paths: p, Log: log}
	a.auditCheck(ctx, &conn{ws: ws}, answers)

	events := log.Recent("audit", 5)
	require.NotEmpty(t, events, "the check recorded its outcome")
	assert.Equal(t, "Audit check: all 2 calls match the relay's audit", events[len(events)-1].Public,
		"the log's first call is matched, and a relay call from before the log began isn't missing")
}

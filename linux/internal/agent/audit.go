package agent

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/tonimelisma/latchkey/linux/internal/activity"
	"github.com/tonimelisma/latchkey/relay/agentproto"
)

// auditCheck compares the server's activity log with the relay's audit after each connection
// (FR-1050; agent-protocol.md, "Audit comparison") and records the outcome in the log.
func (a *Agent) auditCheck(ctx context.Context, c *conn, answers <-chan *agentproto.Audit) {
	entries, err := activity.Read(a.Paths.Activity, time.Time{})
	if err != nil {
		return
	}
	var since time.Time
	for _, e := range entries {
		if e.Kind == "call" && e.CallID != "" {
			since = e.At
			break
		}
	}
	if since.IsZero() {
		return // nothing logged yet to compare
	}
	var relay []activity.RelayEntry
	next := since.UnixMilli()
	for page := 0; page < 1000; page++ {
		id := fmt.Sprintf("a%d", page)
		if err := c.send(ctx, &agentproto.AuditRequest{ID: id, Since: next, Limit: agentproto.MaxAuditEntries}); err != nil {
			return
		}
		var got *agentproto.Audit
		select {
		case <-ctx.Done():
			return
		case got = <-answers:
		case <-time.After(30 * time.Second):
			a.Log.Problem("audit", "Audit check: the relay didn't answer")
			return
		}
		for _, e := range got.Entries {
			relay = append(relay, activity.RelayEntry{CallID: e.CallID, At: time.UnixMilli(e.At), Outcome: e.Outcome})
		}
		if got.NextSince == nil {
			break
		}
		next = *got.NextSince
	}
	a.mu.Lock()
	running := map[string]bool{}
	for id := range a.running {
		running[id] = true
	}
	a.mu.Unlock()
	cutoff := time.Now().Add(-time.Minute) // calls in the last minute may still be finishing
	var recent []activity.Entry
	for _, e := range entries {
		if !e.At.Before(since) && e.At.Before(cutoff) {
			recent = append(recent, e)
		}
	}
	var settled []activity.RelayEntry
	for _, r := range relay {
		if r.At.Before(cutoff) {
			settled = append(settled, r)
		}
	}
	missingHere, missingThere := activity.Compare(recent, settled, running)
	switch {
	case len(missingHere) == 0 && len(missingThere) == 0:
		a.Log.Event("audit", "Audit check: all %d calls match the relay's audit", len(settled))
	default: // call IDs for the Owner only (FR-1053)
		a.Log.Private("audit", true,
			fmt.Sprintf("Audit check: %d calls in the relay's audit aren't in this log (%s); %d logged calls aren't in the relay's audit (%s)",
				len(missingHere), strings.Join(missingHere, ", "), len(missingThere), strings.Join(missingThere, ", ")),
			fmt.Sprintf("Audit check: %d calls in the relay's audit aren't in this log; %d logged calls aren't in the relay's audit",
				len(missingHere), len(missingThere)))
	}
}

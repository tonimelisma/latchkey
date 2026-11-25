package agent

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"os/user"
	"slices"
	"time"

	"github.com/tonimelisma/latchkey/linux/internal/activity"
	"github.com/tonimelisma/latchkey/linux/internal/tools"
	"github.com/tonimelisma/latchkey/relay/agentproto"
)

// reportPart answers the relay's request for this server's part of a problem report (spec 014
// FR-1444, FR-1445): Latchkey's log for the span (only lines latchkey_log would show) and this
// server's own copy of the chat's calls. Asked only by the relay, never listed as a tool.
func (a *Agent) reportPart(raw json.RawMessage) tools.Result {
	var args agentproto.ReportPartArgs
	if err := json.Unmarshal(raw, &args); err != nil {
		return tools.Failf("the request for this server's part couldn't be read: %v", err)
	}
	max := args.MaxBytes
	if max <= 0 || max > agentproto.MaxReportPartBytes {
		max = agentproto.MaxReportPartBytes
	}
	from, to := time.UnixMilli(args.Since).UTC(), time.UnixMilli(args.Until).UTC()
	if to.Before(from) || to.Sub(from) > 48*time.Hour {
		from = to.Add(-48 * time.Hour)
	}
	var part agentproto.ReportPart
	part.Private = privateNames()
	if a.Log == nil {
		part.Notes = append(part.Notes, "this server keeps no log")
		return partResult(part, max)
	}
	entries, err := a.Log.Files().Between(from, to, func(e *activity.Entry) bool {
		return e.Shown() || (e.Kind == "call" && slices.Contains(args.CallIDs, e.CallID))
	})
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		part.Notes = append(part.Notes, "the log couldn't all be read: "+err.Error())
	}
	for _, e := range entries {
		at := e.At.UTC().Format("2006-01-02T15:04:05.000Z")
		if e.Kind == "call" {
			part.Calls = append(part.Calls, agentproto.PartCall{
				CallID: e.CallID, Time: at, Tool: e.Tool, Result: e.Result, IsError: e.IsError, DurationMS: e.DurationMS,
			})
			continue
		}
		part.Log = append(part.Log, agentproto.PartLogLine{Time: at, Category: e.Category, Text: e.Public})
	}
	return partResult(part, max)
}

const leftOutNote = "some of the oldest was left out (size)"

// privateNames are this server's host name, login name and home folder, which the relay replaces
// in the report (spec 014 FR-1449).
func privateNames() []string {
	var out []string
	if h, err := os.Hostname(); err == nil && h != "" {
		out = append(out, h)
	}
	if u, err := user.Current(); err == nil {
		out = append(out, u.HomeDir, u.Username)
	}
	return out
}

// partResult is the part as the call's one text answer, made to fit max bytes: the oldest
// calls' answers go first, then the oldest log lines.
func partResult(part agentproto.ReportPart, max int) tools.Result {
	for {
		b, err := json.Marshal(part)
		if err != nil {
			return tools.Failf("this server's part couldn't be written: %v", err)
		}
		if len(b) <= max {
			return tools.Text(string(b))
		}
		trimmed := false
		for i := range part.Calls {
			if part.Calls[i].Result != nil {
				part.Calls[i].Result = nil
				trimmed = true
				break
			}
		}
		if !trimmed && len(part.Log) > 0 {
			part.Log = part.Log[(len(part.Log)+1)/2:]
			trimmed = true
		}
		if !trimmed && len(part.Calls) > 0 {
			part.Calls = part.Calls[1:]
			trimmed = true
		}
		if !trimmed {
			return tools.Failf("this server's part doesn't fit in %d bytes", max)
		}
		if !slices.Contains(part.Notes, leftOutNote) {
			part.Notes = append(part.Notes, leftOutNote)
		}
	}
}

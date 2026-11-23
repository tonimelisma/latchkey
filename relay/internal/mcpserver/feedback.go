package mcpserver

import (
	"bytes"
	"context"
	"crypto/hpke"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/tonimelisma/latchkey/relay/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/store"
	"github.com/tonimelisma/latchkey/relay/reports"
)

// ReportsOptions is where problem reports go (spec 014 FR-1413 to FR-1415a).
type ReportsOptions struct {
	// IntakeURL is the developer's intake, without a path (default: Latchkey's developer).
	IntakeURL string
	// DeveloperKey is the developer's public key reports are sealed to.
	DeveloperKey hpke.PublicKey
	// Blocked is the operator's block on forwarding (FR-1415a).
	Blocked bool
	// Client sends reports; nil uses a client with a 30 s limit.
	Client *http.Client
	// WorkBits is the proof of work's difficulty; 0 uses reports.WorkBits.
	WorkBits int
}

// MaxReportAge is how long a report waits for the intake before it is dropped (FR-1414).
const MaxReportAge = 7 * 24 * time.Hour

// feedbackLine ends every error answer while the Owner shares problem reports (FR-1406).
const feedbackLine = "If this kept you from what the user needed, report it with the feedback tool."

// feedbackTool is the relay's own tool for problem reports (spec 001 FR-690, spec 014): offered
// only while the Owner shares them (FR-1401). What goes in a report is Claude's judgment; the
// relay changes nothing (FR-1411).
var feedbackTool = &mcp.Tool{
	Name:  agentproto.RelayToolFeedback,
	Title: "Report a Problem with Latchkey",
	Description: "Sends Latchkey's developer a report about anything done with Latchkey that didn't fully work, so it gets fixed; " +
		"the owner chose to share these. File one, before you answer the user, whenever a Latchkey tool gave an error, " +
		"a page or app didn't respond, an answer was wrong, unclear, or missing something, you needed a workaround or " +
		"several tries, or you gave up; one report per problem, even when you found a way around it. " +
		"summary: one line saying what went wrong. details: what you were doing, each tool you called with its arguments " +
		"and what it answered (the relevant parts), what you expected, and what you tried next. machine: the machine it " +
		"was about, if any. The report leaves the owner's hands: never put in it passwords, verification codes, full " +
		"account or card numbers, the text of messages or emails, or anything else private the problem doesn't need; " +
		"describe them instead (\"a 6-digit code\", \"the bank's statements page\"). It is encrypted so only the " +
		"developer can read it. Works even when no machine is online.",
	InputSchema: map[string]any{
		"type": "object",
		"properties": map[string]any{
			"summary": map[string]any{"type": "string", "description": "One line: what went wrong"},
			"details": map[string]any{"type": "string", "description": "What you did, each tool call with its arguments and answer, what you expected, what you tried next; nothing private"},
			"machine": map[string]any{"type": "string", "description": "The machine it was about, by name, if any"},
		},
		"required":             []string{"summary", "details"},
		"additionalProperties": false,
	},
	Annotations: &mcp.ToolAnnotations{ReadOnlyHint: false, DestructiveHint: ptr(false), IdempotentHint: false, OpenWorldHint: ptr(true)},
}

// sharing says whether the Owner shares problem reports: some machine of the account says so,
// and the relay can and may forward them (FR-1401, FR-1415a).
func (s *Server) sharing(ms []machine) bool {
	r := s.opts.Reports
	if r.Blocked || r.DeveloperKey == nil || r.IntakeURL == "" {
		return false
	}
	for _, m := range ms {
		if m.State != nil && m.State.ShareReports != nil && *m.State.ShareReports {
			return true
		}
	}
	return false
}

// SharingChanged follows a machine's changed choice: the tool list, and with no machine
// sharing any more, the account's waiting reports are dropped (FR-1403).
func (s *Server) SharingChanged(userID string) {
	ctx := context.Background()
	if !s.sharing(s.machines(ctx, userID)) {
		if n, err := s.store.DropUserReports(ctx, userID); err != nil {
			s.opts.Logger.Error("drop waiting reports", "user", userID, "err", err)
		} else if n > 0 {
			s.opts.Logger.Info("sharing turned off: waiting reports dropped", "user", userID, "reports", n)
		}
	}
	s.ToolsChanged(userID)
}

// fileFeedback answers the feedback tool: the report is sealed to the developer's key and
// queued for the intake (FR-1410 to FR-1416).
func (s *Server) fileFeedback(userID string) mcp.ToolHandler {
	return func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		start := s.opts.Now()
		client := surface(req)
		args := map[string]any{}
		_ = json.Unmarshal(req.Params.Arguments, &args)
		text := func(k string, max int) string {
			v, _ := args[k].(string)
			return truncate(strings.TrimSpace(v), max)
		}
		summary := text("summary", agentproto.MaxFeedbackSummary)
		var result *mcp.CallToolResult
		outcome := store.OutcomeOK
		ms := s.machines(ctx, userID)
		switch {
		case !s.sharing(ms):
			result, outcome = errorResult("The owner doesn't share problem reports now, so nothing was sent."), store.OutcomeError
		case summary == "":
			result, outcome = errorResult("Give a summary: one line saying what went wrong."), store.OutcomeError
		default:
			r := s.report(userID, ms, text("machine", agentproto.MaxFeedbackName), summary,
				text("details", agentproto.MaxFeedbackDetails), truncate(client, agentproto.MaxFeedbackName), start)
			id := agentproto.NewFeedbackID()
			sealed, err := reports.Seal(s.opts.Reports.DeveloperKey, r)
			if err == nil {
				err = s.store.AddReport(ctx, store.OutboxReport{ID: id, UserID: userID, Created: start.UTC(), Sealed: sealed})
			}
			if err != nil {
				s.opts.Logger.Error("queue report", "user", userID, "err", err)
				result, outcome = errorResult("The report couldn't be queued; tell the user what went wrong instead."), store.OutcomeError
			} else {
				s.kickReports()
				result = &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{
					Text: "Thank you: the report is encrypted and queued for Latchkey's developer (" + id + "). Carry on with the user's task.",
				}}}
			}
		}
		// The trace keeps the call's arguments as the Owner's own record, as for every call (FR-683).
		s.trace(userID, start, agentproto.NewCallID(), client, agentproto.RelayToolFeedback, "", req, result, outcome)
		return result, nil
	}
}

// report builds what a shared report holds (FR-1412): no account, email address, machine name,
// or relay address.
func (s *Server) report(userID string, ms []machine, named, summary, details, client string, at time.Time) reports.Report {
	r := reports.Report{At: at.UTC(), Summary: summary, Details: details, Client: client, RelayVersion: s.opts.Version}
	if tag, err := s.store.ReporterTag(userID); err == nil {
		r.Reporter = tag
	}
	var m *machine
	for i := range ms {
		if named != "" && strings.EqualFold(ms[i].Device.Name, named) {
			m = &ms[i]
		}
	}
	if m == nil && len(ms) == 1 {
		m = &ms[0]
	}
	if m != nil {
		r.MachineVersion = m.Device.AppVersion
		r.System = m.Device.OSVersion
		if m.Device.Kind == store.KindMac && m.Device.OSVersion != "" {
			r.System = "macOS " + m.Device.OSVersion
		}
		if m.State != nil && m.State.ScreenLocked != nil {
			r.Screen = map[bool]string{true: "locked", false: "unlocked"}[*m.State.ScreenLocked]
		}
	}
	return r
}

// kickReports wakes the sender at once.
func (s *Server) kickReports() {
	select {
	case s.reportsKick <- struct{}{}:
	default:
	}
}

// SendReports delivers queued reports to the intake until ctx ends: each with a fresh proof of
// work, retried with backoff, deleted once accepted or refused for good, and dropped after
// MaxReportAge (FR-1414).
func (s *Server) SendReports(ctx context.Context) {
	tick := time.NewTicker(time.Minute)
	defer tick.Stop()
	for {
		s.sendDueReports(ctx)
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		case <-s.reportsKick:
		}
	}
}

func (s *Server) sendDueReports(ctx context.Context) {
	r := s.opts.Reports
	if r.IntakeURL == "" || r.Blocked {
		return
	}
	client := r.Client
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	work := r.WorkBits
	if work == 0 {
		work = reports.WorkBits
	}
	now := s.opts.Now()
	due, err := s.store.DueReports(ctx, now, 20)
	if err != nil {
		s.opts.Logger.Error("read report outbox", "err", err)
		return
	}
	for _, rep := range due {
		if ctx.Err() != nil {
			return
		}
		if now.Sub(rep.Created) > MaxReportAge {
			_ = s.store.ReportDone(ctx, rep.ID)
			s.opts.Logger.Warn("report dropped: the intake didn't accept it within 7 days", "report", rep.ID, "tries", rep.Tries)
			continue
		}
		hour := reports.Hour(s.opts.Now())
		nonce := reports.Prove(rep.Sealed, hour, work)
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(r.IntakeURL, "/")+"/v1/reports", bytes.NewReader(rep.Sealed))
		if err != nil {
			s.opts.Logger.Error("report request", "err", err)
			return
		}
		req.Header.Set("Content-Type", "application/octet-stream")
		req.Header.Set("Latchkey-Work-Hour", hour)
		req.Header.Set("Latchkey-Work-Nonce", strconv.FormatUint(nonce, 10))
		resp, err := client.Do(req)
		status := 0
		if err == nil {
			status = resp.StatusCode
			_ = resp.Body.Close()
		}
		switch status {
		case http.StatusAccepted, http.StatusOK:
			_ = s.store.ReportDone(ctx, rep.ID)
		case http.StatusBadRequest, http.StatusRequestEntityTooLarge:
			_ = s.store.ReportDone(ctx, rep.ID) // never accepted, however often sent
			s.opts.Logger.Error("report refused by the intake", "report", rep.ID, "status", status)
		default: // unreachable, busy, over the limit, or an old proof: later
			wait := time.Minute << min(rep.Tries, 10) // 1 minute, doubling, up to about 17 hours
			_ = s.store.ReportRetry(ctx, rep.ID, s.opts.Now().Add(wait))
			if err != nil {
				s.opts.Logger.Warn("report not delivered", "report", rep.ID, "err", err)
			} else {
				s.opts.Logger.Warn("report not delivered", "report", rep.ID, "status", status)
			}
		}
	}
}

func truncate(v string, max int) string {
	if utf8.RuneCountInString(v) > max {
		return string([]rune(v)[:max])
	}
	return v
}

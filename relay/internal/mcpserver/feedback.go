package mcpserver

import (
	"bytes"
	"context"
	"crypto/hpke"
	"encoding/json"
	"fmt"
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

// MaxReportsPerHour is how many reports one account may file an hour.
const MaxReportsPerHour = 20

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
		"The report carries this chat's Latchkey tool calls with their arguments and answers, Latchkey's logs on the relay " +
		"and the machines involved, and the pages the chat used (each page's address, source, requests, errors, and whether " +
		"it was drawing), with passwords, codes, and cookie values left out; so don't copy them into details. " +
		"summary: one line saying what went wrong. details: what you were doing, what you saw, what you expected, and what " +
		"you tried next, in your own words. machines: every machine " +
		"the problem involved, by name as the machines tool lists them; name each one whenever a machine was involved " +
		"(the report then carries its Latchkey and system versions and screen state, never its name). The report leaves the owner's hands: never put in it passwords, verification codes, full " +
		"account or card numbers, the text of messages or emails, or anything else private the problem doesn't need; " +
		"describe them instead (\"a 6-digit code\", \"the bank's statements page\"). It is encrypted so only the " +
		"developer can read it. Works even when no machine is online.",
	InputSchema: map[string]any{
		"type": "object",
		"properties": map[string]any{
			"summary": map[string]any{"type": "string", "description": "One line: what went wrong"},
			"details": map[string]any{"type": "string", "description": "What you did and saw, what you expected, what you tried next; the calls themselves come with the report; nothing private"},
			"machines": map[string]any{
				"type": "array", "items": map[string]any{"type": "string"},
				"description": "Every machine the problem involved, by name as the machines tool lists them; empty only when none was",
			},
			// Chats that started before 2026-11-24 still send the single name.
			"machine": map[string]any{"type": "string", "description": "One machine it was about; use machines instead"},
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
		case !s.reportRate.Allow(userID):
			result, outcome = errorResult(fmt.Sprintf("This account filed %d reports in the last hour; file this one later.", MaxReportsPerHour)), store.OutcomeError
		default:
			var named []string
			if one := text("machine", agentproto.MaxFeedbackName); one != "" {
				named = append(named, one)
			}
			if list, ok := args["machines"].([]any); ok {
				for _, v := range list {
					if n, ok := v.(string); ok && strings.TrimSpace(n) != "" && len(named) < 16 {
						named = append(named, truncate(strings.TrimSpace(n), agentproto.MaxFeedbackName))
					}
				}
			}
			r := s.report(userID, ms, named, summary,
				text("details", agentproto.MaxFeedbackDetails), truncate(client, agentproto.MaxFeedbackName), start)
			id := agentproto.NewFeedbackID()
			r.ID = id
			// Everything for the chat (FR-1440 to FR-1451), and the small version for an older
			// intake (FR-1451); both sealed, the relay keeps neither readable.
			full, small, err := s.fullReport(ctx, userID, req, ms, named, r, start)
			var sealed, sealedSmall []byte
			if err == nil {
				sealed, err = reports.SealRaw(s.opts.Reports.DeveloperKey, full)
			}
			if err == nil {
				sealedSmall, err = reports.SealRaw(s.opts.Reports.DeveloperKey, small)
			}
			if err == nil {
				err = s.store.AddReport(ctx, store.OutboxReport{ID: id, UserID: userID, Created: start.UTC(), Sealed: sealed, Small: sealedSmall})
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
func (s *Server) report(userID string, ms []machine, named []string, summary, details, client string, at time.Time) reports.Report {
	r := reports.Report{Format: 2, At: at.UTC(), Summary: summary, Details: details, Client: client, RelayVersion: s.opts.Version}
	if tag, err := s.store.ReporterTag(userID); err == nil {
		r.Reporter = tag
	}
	r.Machines = reportMachines(ms, named)
	return r
}

// reportMachines says what a report holds about machines (FR-1412; decided 2026-11-24): each
// machine Claude named, or, when it named none it knows, every machine online now. Names that
// match no machine are left out; a machine's name never goes in.
func reportMachines(ms []machine, named []string) []reports.Machine {
	var out []reports.Machine
	for _, m := range ms {
		for _, n := range named {
			if strings.EqualFold(m.Device.Name, n) {
				out = append(out, machineFacts(m, true))
				break
			}
		}
	}
	if len(out) > 0 {
		return out
	}
	for _, m := range ms {
		if m.Online {
			out = append(out, machineFacts(m, false))
		}
	}
	return out
}

func machineFacts(m machine, named bool) reports.Machine {
	f := reports.Machine{Named: named, Kind: m.Device.Kind, Version: m.Device.AppVersion, System: m.Device.OSVersion}
	if f.Kind == "" {
		f.Kind = store.KindMac
	}
	if f.Kind == store.KindMac && f.System != "" {
		f.System = "macOS " + f.System
	}
	if m.State != nil && m.State.ScreenLocked != nil {
		f.Screen = map[bool]string{true: "locked", false: "unlocked"}[*m.State.ScreenLocked]
	}
	return f
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
		client = &http.Client{Timeout: 2 * time.Minute} // reports reach 5 MB (FR-1450)
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
		// The Owner's choice is checked again right before sending, not only when the report was
		// filed: sharing turned off meanwhile, or the sharing machine was removed, means the
		// report never leaves (FR-1403; security review 2026-11-23).
		if !s.sharing(s.machines(ctx, rep.UserID)) {
			_ = s.store.ReportDone(ctx, rep.ID)
			s.opts.Logger.Info("report dropped: the owner no longer shares", "report", rep.ID)
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
		case http.StatusRequestEntityTooLarge:
			// An intake from before 5 MB reports (FR-1451): its small version goes instead, once.
			if small, err := s.store.ReportUseSmall(ctx, rep.ID); err == nil && small {
				s.opts.Logger.Warn("the intake takes only small reports: sending the report without the chat's calls, logs and pages", "report", rep.ID)
				s.kickReports()
				continue
			}
			_ = s.store.ReportDone(ctx, rep.ID)
			s.opts.Logger.Error("report refused by the intake", "report", rep.ID, "status", status)
		case http.StatusBadRequest:
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

package mcpserver

import (
	"context"
	"encoding/json"
	"strings"
	"unicode/utf8"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/tonimelisma/latchkey/relay/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// feedbackTool is the relay's own tool for Claude's reports of anything that didn't work
// (spec 001 FR-690); it works whether or not a machine is online (FR-691).
var feedbackTool = &mcp.Tool{
	Name:  agentproto.RelayToolFeedback,
	Title: "Report a Problem with Latchkey",
	Description: "Tells Latchkey's developer about anything done with Latchkey that didn't fully work, so it gets fixed. " +
		"File one, before you answer the user, whenever a Latchkey tool gave an error, a page or app didn't respond, " +
		"an answer was wrong, unclear, or missing something, you needed a workaround or several tries, or you gave up; " +
		"one report per problem, even when you found a way around it. " +
		"summary: one line saying what went wrong. details: what you were doing, each tool you called with its arguments " +
		"and what it answered (quote the relevant parts), what you expected, and what you tried next. " +
		"machine: the machine it was about, if any. Works even when no machine is online. " +
		"The report is kept for the owner's investigation; no one is notified and nothing is sent anywhere else.",
	InputSchema: map[string]any{
		"type": "object",
		"properties": map[string]any{
			"summary": map[string]any{"type": "string", "description": "One line: what went wrong"},
			"details": map[string]any{"type": "string", "description": "What you did, each tool call with its arguments and answer, what you expected, what you tried next"},
			"machine": map[string]any{"type": "string", "description": "The machine it was about, by name, if any"},
		},
		"required":             []string{"summary", "details"},
		"additionalProperties": false,
	},
	Annotations: &mcp.ToolAnnotations{ReadOnlyHint: false, DestructiveHint: ptr(false), IdempotentHint: false, OpenWorldHint: ptr(false)},
}

// fileFeedback answers the feedback tool: the report is kept, and sent to the account's Macs
// that are connected (FR-691, FR-692).
func (s *Server) fileFeedback(userID string) mcp.ToolHandler {
	return func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		start := s.opts.Now()
		client := surface(req)
		args := map[string]any{}
		_ = json.Unmarshal(req.Params.Arguments, &args)
		text := func(k string, max int) string {
			v, _ := args[k].(string)
			v = strings.TrimSpace(v)
			if utf8.RuneCountInString(v) > max {
				v = string([]rune(v)[:max])
			}
			return v
		}
		summary := text("summary", agentproto.MaxFeedbackSummary)
		var result *mcp.CallToolResult
		outcome := store.OutcomeOK
		if summary == "" {
			result, outcome = errorResult("Give a summary: one line saying what went wrong."), store.OutcomeError
		} else {
			f := store.Feedback{
				ID: agentproto.NewFeedbackID(), UserID: userID, At: start.UTC(),
				Client:  truncate(client, agentproto.MaxFeedbackName),
				Machine: text("machine", agentproto.MaxFeedbackName),
				Summary: summary, Details: text("details", agentproto.MaxFeedbackDetails),
			}
			if err := s.store.AddFeedback(ctx, f); err != nil {
				s.opts.Logger.Error("keep feedback", "user", userID, "err", err)
				result, outcome = errorResult("The report couldn't be kept; please tell the user what went wrong instead."), store.OutcomeError
			} else {
				s.hub.FeedbackFiled(context.WithoutCancel(ctx), userID)
				result = &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{
					Text: "Thank you: the report is kept for the owner to investigate (" + f.ID + "). Carry on with the user's task.",
				}}}
			}
		}
		s.trace(userID, start, agentproto.NewCallID(), client, agentproto.RelayToolFeedback, "", req, result, outcome)
		return result, nil
	}
}

func truncate(v string, max int) string {
	if utf8.RuneCountInString(v) > max {
		return string([]rune(v)[:max])
	}
	return v
}

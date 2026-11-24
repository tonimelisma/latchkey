package evals

import (
	"bufio"
	"encoding/json"
	"io"
	"strings"
)

// ServerPrefix is how Claude Code names Latchkey's tools when the MCP server is called latchkey.
const ServerPrefix = "mcp__latchkey__"

// Call is one tool call Claude made, with its answer.
type Call struct {
	Tool    string          `json:"tool"`
	Input   json.RawMessage `json:"input,omitempty"`
	IsError bool            `json:"is_error,omitempty"`
	// Answer is the tool's text, cut to answerLimit.
	Answer string `json:"answer,omitempty"`
}

// Transcript is what an eval reads from Claude Code's `--output-format stream-json --verbose`.
type Transcript struct {
	// MCP is each MCP server's status from system/init ("connected", "failed", …).
	MCP map[string]string `json:"mcp,omitempty"`
	// Tools is the tool names Claude Code offered (system/init).
	Tools     []string `json:"-"`
	Calls     []Call   `json:"calls"`
	Turns     int      `json:"turns"`
	TokensIn  int      `json:"tokens_in"`
	TokensOut int      `json:"tokens_out"`
	// Subtype is the result's ("success", "error_max_turns", …); Final is Claude's last text.
	Subtype           string `json:"subtype,omitempty"`
	IsError           bool   `json:"is_error,omitempty"`
	Final             string `json:"final,omitempty"`
	PermissionDenials int    `json:"permission_denials,omitempty"`
	HasResult         bool   `json:"-"`
}

const answerLimit = 2000

type event struct {
	Type       string `json:"type"`
	Subtype    string `json:"subtype"`
	MCPServers []struct {
		Name   string `json:"name"`
		Status string `json:"status"`
	} `json:"mcp_servers"`
	Tools   []string `json:"tools"`
	Message struct {
		Content []struct {
			Type      string          `json:"type"`
			ID        string          `json:"id"`
			Name      string          `json:"name"`
			Input     json.RawMessage `json:"input"`
			ToolUseID string          `json:"tool_use_id"`
			Content   json.RawMessage `json:"content"`
			IsError   bool            `json:"is_error"`
		} `json:"content"`
	} `json:"message"`
	NumTurns int `json:"num_turns"`
	Usage    struct {
		InputTokens              int `json:"input_tokens"`
		OutputTokens             int `json:"output_tokens"`
		CacheReadInputTokens     int `json:"cache_read_input_tokens"`
		CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
	} `json:"usage"`
	IsError           bool              `json:"is_error"`
	Result            string            `json:"result"`
	PermissionDenials []json.RawMessage `json:"permission_denials"`
}

// ParseStream reads Claude Code's stream-json lines. Lines that aren't JSON are skipped.
func ParseStream(r io.Reader) (Transcript, error) {
	t := Transcript{MCP: map[string]string{}}
	byID := map[string]int{}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 1<<20), 64<<20)
	for sc.Scan() {
		var e event
		if json.Unmarshal(sc.Bytes(), &e) != nil {
			continue
		}
		switch e.Type {
		case "system":
			if e.Subtype == "init" {
				for _, s := range e.MCPServers {
					t.MCP[s.Name] = s.Status
				}
				t.Tools = e.Tools
			}
		case "assistant":
			for _, c := range e.Message.Content {
				if c.Type == "tool_use" {
					byID[c.ID] = len(t.Calls)
					t.Calls = append(t.Calls, Call{Tool: strings.TrimPrefix(c.Name, ServerPrefix), Input: c.Input})
				}
			}
		case "user":
			for _, c := range e.Message.Content {
				if c.Type != "tool_result" {
					continue
				}
				if i, ok := byID[c.ToolUseID]; ok {
					t.Calls[i].IsError = c.IsError
					t.Calls[i].Answer = cut(resultText(c.Content), answerLimit)
				}
			}
		case "result":
			t.HasResult = true
			t.Subtype, t.IsError, t.Final = e.Subtype, e.IsError, cut(e.Result, answerLimit)
			t.Turns = e.NumTurns
			t.TokensIn = e.Usage.InputTokens + e.Usage.CacheReadInputTokens + e.Usage.CacheCreationInputTokens
			t.TokensOut = e.Usage.OutputTokens
			t.PermissionDenials = len(e.PermissionDenials)
		}
	}
	return t, sc.Err()
}

// resultText is a tool result's text: a plain string, or the text parts of a content list.
func resultText(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var parts []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &parts) == nil {
		var b strings.Builder
		for _, p := range parts {
			if p.Type == "text" {
				b.WriteString(p.Text)
			} else {
				b.WriteString("[" + p.Type + "]")
			}
		}
		return b.String()
	}
	return string(raw)
}

func cut(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

// LatchkeyConnected says whether Claude Code loaded Latchkey and nothing else (FR-1523).
func (t Transcript) LatchkeyConnected() bool {
	return t.MCP["latchkey"] == "connected" && len(t.MCP) == 1
}

// ToolErrors counts the calls that answered an error.
func (t Transcript) ToolErrors() int {
	n := 0
	for _, c := range t.Calls {
		if c.IsError {
			n++
		}
	}
	return n
}

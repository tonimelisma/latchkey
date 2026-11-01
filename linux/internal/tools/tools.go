// Package tools is what the Linux program's tools have in common: their MCP definitions, their
// arguments, and their results (text, or an image, never structured content: Claude's apps would
// show that instead of the text).
package tools

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/tonimelisma/latchkey/relay/agentproto"
)

// Content is one MCP content block.
type Content map[string]any

// Result is a tool's answer.
type Result struct {
	Content []Content
	IsError bool
}

// Text answers with text.
func Text(s string) Result { return Result{Content: []Content{{"type": "text", "text": s}}} }

// Failf answers with an error Claude can act on.
func Failf(format string, a ...any) Result {
	r := Text(fmt.Sprintf(format, a...))
	r.IsError = true
	return r
}

// Image answers with a picture Claude sees.
func Image(data []byte, mimeType string) Result {
	return Result{Content: []Content{{"type": "image", "data": base64.StdEncoding.EncodeToString(data), "mimeType": mimeType}}}
}

// Encode turns the result into the protocol's result for a call.
func (r Result) Encode(callID string) *agentproto.Result {
	content, err := json.Marshal(r.Content)
	if err != nil {
		content, _ = json.Marshal([]Content{{"type": "text", "text": "The result couldn't be encoded: " + err.Error()}})
		r.IsError = true
	}
	return &agentproto.Result{ID: callID, Content: content, IsError: r.IsError}
}

// Tool is one tool: its definition and what runs it.
type Tool struct {
	Def *mcp.Tool
	Run func(ctx context.Context, args Args) Result
}

// Spec describes a tool for Make.
type Spec struct {
	Name, Title, Description string
	Input                    map[string]any // property name → JSON schema
	Required                 []string
	ReadOnly                 bool
	Destructive              bool
	OpenWorld                bool
	DeadlineMS               int // 0: the relay's default
}

// Make builds an MCP tool definition.
func Make(s Spec) *mcp.Tool {
	schema := map[string]any{"type": "object", "properties": s.Input}
	if s.Input == nil {
		schema["properties"] = map[string]any{}
	}
	if len(s.Required) > 0 {
		req := make([]any, len(s.Required))
		for i, r := range s.Required {
			req[i] = r
		}
		schema["required"] = req
	}
	t := &mcp.Tool{
		Name: s.Name, Title: s.Title, Description: s.Description, InputSchema: schema,
		Annotations: &mcp.ToolAnnotations{
			ReadOnlyHint: s.ReadOnly, DestructiveHint: &s.Destructive, OpenWorldHint: &s.OpenWorld,
		},
	}
	if s.DeadlineMS > 0 {
		t.Meta = mcp.Meta{agentproto.DeadlineMetaKey: float64(s.DeadlineMS)}
	}
	return t
}

// String is a string property's schema.
func String(desc string) map[string]any { return map[string]any{"type": "string", "description": desc} }

// Integer is an integer property's schema.
func Integer(desc string) map[string]any {
	return map[string]any{"type": "integer", "description": desc}
}

// Bool is a boolean property's schema.
func Bool(desc string) map[string]any { return map[string]any{"type": "boolean", "description": desc} }

// Enum is a string property with fixed values.
func Enum(values []string, desc string) map[string]any {
	vs := make([]any, len(values))
	for i, v := range values {
		vs[i] = v
	}
	return map[string]any{"type": "string", "enum": vs, "description": desc}
}

// Args are a call's arguments.
type Args map[string]any

// ParseArgs reads a call's arguments; none is an empty set.
func ParseArgs(raw json.RawMessage) (Args, error) {
	a := Args{}
	if len(raw) == 0 || string(raw) == "null" {
		return a, nil
	}
	if err := json.Unmarshal(raw, &a); err != nil {
		return nil, fmt.Errorf("the arguments aren't a JSON object: %w", err)
	}
	return a, nil
}

// Has reports whether the argument was given (and isn't null or an empty string).
func (a Args) Has(name string) bool {
	v, ok := a[name]
	if !ok || v == nil {
		return false
	}
	s, isString := v.(string)
	return !isString || s != ""
}

// String is a string argument, "" when missing.
func (a Args) String(name string) (string, error) {
	v, ok := a[name]
	if !ok || v == nil {
		return "", nil
	}
	s, isString := v.(string)
	if !isString {
		return "", fmt.Errorf("%s must be text", name)
	}
	return s, nil
}

// Bool is a boolean argument, def when missing.
func (a Args) Bool(name string, def bool) (bool, error) {
	v, ok := a[name]
	if !ok || v == nil {
		return def, nil
	}
	b, isBool := v.(bool)
	if !isBool {
		return false, fmt.Errorf("%s must be true or false", name)
	}
	return b, nil
}

// Int is a whole-number argument within [lo, hi], def when missing.
func (a Args) Int(name string, def, lo, hi int) (int, error) {
	v, ok := a[name]
	if !ok || v == nil {
		return def, nil
	}
	f, isNumber := v.(float64) // what JSON gives
	if n, isInt := v.(int); isInt {
		f, isNumber = float64(n), true
	}
	if !isNumber || f != math.Trunc(f) {
		return 0, fmt.Errorf("%s must be a whole number", name)
	}
	if f < float64(lo) || f > float64(hi) {
		return 0, fmt.Errorf("%s must be from %d to %d", name, lo, hi)
	}
	return int(f), nil
}

// Strings is a list-of-text argument.
func (a Args) Strings(name string) ([]string, error) {
	v, ok := a[name]
	if !ok || v == nil {
		return nil, nil
	}
	list, isList := v.([]any)
	if !isList {
		return nil, fmt.Errorf("%s must be a list", name)
	}
	out := make([]string, 0, len(list))
	for _, item := range list {
		s, isString := item.(string)
		if !isString {
			return nil, fmt.Errorf("%s must be a list of text", name)
		}
		out = append(out, s)
	}
	return out, nil
}

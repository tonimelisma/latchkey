package mcpserver

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"slices"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/tonimelisma/latchkey/relay/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Several machines behind one connector (spec 010, plan D2, D4, D6): the tool list is the union
// of the machines' tools, one copy per name with a machine argument; each call is routed to the
// machine it names, or to the only one that can run it.

// machine is one paired machine as the relay knows it.
type machine struct {
	Device        store.Device
	Online        bool
	LastSeen      time.Time
	OfflineReason string
	State         *agentproto.State // last reported; nil if never reported
	Tools         []*mcp.Tool       // last reported list
}

func (m machine) tool(name string) *mcp.Tool {
	for _, t := range m.Tools {
		if t.Name == name {
			return t
		}
	}
	return nil
}

// machines reads the Owner's paired machines, oldest pairing first.
func (s *Server) machines(ctx context.Context, userID string) []machine {
	devices, err := s.store.ActiveDevices(ctx, userID)
	if err != nil {
		return nil
	}
	out := make([]machine, 0, len(devices))
	for _, d := range devices {
		m := machine{Device: d, Online: s.hub.Online(d.ID)}
		if st, err := s.store.DeviceState(ctx, d.ID); err == nil {
			m.LastSeen, m.OfflineReason = st.LastSeenAt, st.OfflineReason
			if st.StateJSON != nil {
				var state agentproto.State
				if json.Unmarshal(st.StateJSON, &state) == nil {
					m.State = &state
				}
			}
			if st.ToolsJSON != nil {
				var tools []*mcp.Tool
				switch err := json.Unmarshal(st.ToolsJSON, &tools); {
				case err != nil:
					s.opts.Logger.Error("stored tools unreadable", "device", d.ID, "err", err)
				case agentproto.ValidateTools(tools) == nil: // validated on arrival too; never hand the SDK a tool it would panic on
					m.Tools = tools
				}
			}
		}
		out = append(out, m)
	}
	return out
}

// kindOrder puts Macs before Linux servers in merged descriptions.
var kindOrder = []string{store.KindMac, store.KindLinux}

const machineArgDescription = "The machine to use, by name, as the machines tool lists it. Leave it out when only one machine offers this tool."

// machinesTool is the relay's own list of the Owner's machines (FR-1006).
var machinesTool = &mcp.Tool{
	Name:  agentproto.RelayToolMachines,
	Title: "Your Machines",
	Description: "Lists the machines Claude can reach through Latchkey: each one's name, whether it's a Mac or a Linux server, " +
		"whether it's online (or when it was last seen), and the tools it offers. Call it when you don't know which machine to use; " +
		"then pass the name as machine to the other tools.",
	InputSchema: map[string]any{"type": "object", "properties": map[string]any{}, "additionalProperties": false},
	Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true, OpenWorldHint: ptr(false)},
}

func ptr[T any](v T) *T { return &v }

// mergedTools is what Claude sees: the machines tool (while any machine is paired) and one tool
// per name any machine offers, with descriptions per kind of machine and the machine argument.
func mergedTools(ms []machine) []*mcp.Tool {
	if len(ms) == 0 {
		return nil
	}
	var names []string
	for _, m := range ms {
		for _, t := range m.Tools {
			if !slices.Contains(names, t.Name) {
				names = append(names, t.Name)
			}
		}
	}
	slices.Sort(names)
	out := []*mcp.Tool{machinesTool}
	for _, name := range names {
		out = append(out, mergeTool(name, ms))
	}
	return out
}

// mergeTool builds one tool from the definitions the machines give for name: per kind, the
// definition of that kind's most recently seen machine.
func mergeTool(name string, ms []machine) *mcp.Tool {
	type def struct {
		kind string
		tool *mcp.Tool
		seen time.Time
	}
	var defs []def
	for _, kind := range kindOrder {
		var best *def
		for _, m := range ms {
			t := m.tool(name)
			if t == nil || m.Device.Kind != kind {
				continue
			}
			if best == nil || m.LastSeen.After(best.seen) {
				best = &def{kind, t, m.LastSeen}
			}
		}
		if best != nil {
			defs = append(defs, *best)
		}
	}
	merged := copyTool(defs[0].tool)
	if len(defs) > 1 {
		var parts []string
		for _, d := range defs {
			parts = append(parts, "On a "+kindPhrase(d.kind)+": "+d.tool.Description)
		}
		merged.Description = strings.Join(parts, "\n\n")
		schemas := make([]map[string]any, len(defs))
		kinds := make([]string, len(defs))
		for i, d := range defs {
			schemas[i], _ = toMap(d.tool.InputSchema)
			kinds[i] = d.kind
		}
		merged.InputSchema = unionSchema(schemas, kinds)
		merged.Annotations = unionAnnotations(defs[0].tool.Annotations, defs[1].tool.Annotations)
		if !reflect.DeepEqual(defs[0].tool.OutputSchema, defs[1].tool.OutputSchema) {
			merged.OutputSchema = nil
		}
		deadline := time.Duration(0)
		for _, d := range defs {
			deadline = max(deadline, agentproto.ToolDeadline(d.tool))
		}
		if merged.Meta == nil {
			merged.Meta = mcp.Meta{}
		}
		merged.Meta[agentproto.DeadlineMetaKey] = float64(deadline.Milliseconds())
	}
	schema, _ := toMap(merged.InputSchema)
	if schema == nil {
		schema = map[string]any{"type": "object"}
	}
	props, _ := schema["properties"].(map[string]any)
	if props == nil {
		props = map[string]any{}
	}
	props[agentproto.MachineArgument] = map[string]any{"type": "string", "description": machineArgDescription}
	schema["properties"] = props
	merged.InputSchema = schema
	return merged
}

func kindPhrase(kind string) string {
	if kind == store.KindLinux {
		return "Linux server"
	}
	return "Mac"
}

func copyTool(t *mcp.Tool) *mcp.Tool {
	data, err := json.Marshal(t)
	if err != nil {
		return t
	}
	var out mcp.Tool
	if json.Unmarshal(data, &out) != nil {
		return t
	}
	return &out
}

func toMap(v any) (map[string]any, bool) {
	data, err := json.Marshal(v)
	if err != nil {
		return nil, false
	}
	var m map[string]any
	if json.Unmarshal(data, &m) != nil {
		return nil, false
	}
	return m, true
}

// unionSchema unites object schemas: every property of any of them (the first definition wins,
// enum values are united), a property some kinds lack marked "(Mac only)" or "(Linux servers
// only)", and required only what all require.
func unionSchema(schemas []map[string]any, kinds []string) map[string]any {
	out := map[string]any{"type": "object"}
	props := map[string]any{}
	has := map[string][]string{}
	var order []string
	for i, s := range schemas {
		p, _ := s["properties"].(map[string]any)
		keys := make([]string, 0, len(p))
		for k := range p {
			keys = append(keys, k)
		}
		slices.Sort(keys)
		for _, k := range keys {
			has[k] = append(has[k], kinds[i])
			prop, _ := p[k].(map[string]any)
			old, seen := props[k].(map[string]any)
			if !seen {
				props[k] = prop
				order = append(order, k)
				continue
			}
			if a, ok := old["enum"].([]any); ok {
				if b, ok := prop["enum"].([]any); ok {
					for _, v := range b {
						if !slices.Contains(a, v) {
							a = append(a, v)
						}
					}
					old["enum"] = a
				}
			}
		}
	}
	for _, k := range order {
		if len(has[k]) < len(kinds) {
			prop, _ := props[k].(map[string]any)
			if prop == nil {
				prop = map[string]any{}
			}
			desc, _ := prop["description"].(string)
			note := "(" + kindPhrase(has[k][0]) + " only)"
			if has[k][0] == store.KindLinux {
				note = "(Linux servers only)"
			}
			prop["description"] = strings.TrimSpace(desc + " " + note)
			props[k] = prop
		}
	}
	out["properties"] = props
	var required []any
	if first, ok := schemas[0]["required"].([]any); ok {
		for _, r := range first {
			all := true
			for _, s := range schemas[1:] {
				if req, _ := s["required"].([]any); !slices.Contains(req, r) {
					all = false
				}
			}
			if all {
				required = append(required, r)
			}
		}
	}
	if len(required) > 0 {
		out["required"] = required
	}
	return out
}

// unionAnnotations: read-only and idempotent only if both are; destructive and open-world if
// either is (or doesn't say, which MCP reads as yes).
func unionAnnotations(a, b *mcp.ToolAnnotations) *mcp.ToolAnnotations {
	if a == nil || b == nil {
		return nil
	}
	yes := func(p *bool) bool { return p == nil || *p }
	return &mcp.ToolAnnotations{
		ReadOnlyHint:    a.ReadOnlyHint && b.ReadOnlyHint,
		IdempotentHint:  a.IdempotentHint && b.IdempotentHint,
		DestructiveHint: ptr(yes(a.DestructiveHint) || yes(b.DestructiveHint)),
		OpenWorldHint:   ptr(yes(a.OpenWorldHint) || yes(b.OpenWorldHint)),
		Title:           a.Title,
	}
}

// takeMachine removes the machine argument from a call's arguments and returns it.
func takeMachine(args json.RawMessage) (name string, rest json.RawMessage) {
	var m map[string]json.RawMessage
	if len(args) == 0 || json.Unmarshal(args, &m) != nil {
		return "", args
	}
	raw, ok := m[agentproto.MachineArgument]
	if !ok {
		return "", args
	}
	_ = json.Unmarshal(raw, &name)
	delete(m, agentproto.MachineArgument)
	rest, err := json.Marshal(m)
	if err != nil {
		return name, args
	}
	return strings.TrimSpace(name), rest
}

// choose picks the machine for a call of tool (plan D4). It returns the machine, or the text
// that answers the call instead.
func choose(ms []machine, tool, named string, now time.Time) (machine, string) {
	var offering []machine
	for _, m := range ms {
		if m.tool(tool) != nil {
			offering = append(offering, m)
		}
	}
	if named != "" {
		for _, m := range ms {
			if store.NameKey(m.Device.Name) != store.NameKey(named) {
				continue
			}
			if m.tool(tool) == nil {
				if len(offering) == 0 {
					return machine{}, fmt.Sprintf("No machine offers %s.", tool)
				}
				return machine{}, fmt.Sprintf("%s doesn't offer %s. It's offered by: %s.", m.Device.Name, tool, list(offering, now))
			}
			return m, ""
		}
		return machine{}, fmt.Sprintf("No machine is called %q. Your machines: %s.", named, list(ms, now))
	}
	switch {
	case len(offering) == 0:
		return machine{}, fmt.Sprintf("No machine offers %s.", tool)
	case len(offering) == 1:
		return offering[0], ""
	}
	var online []machine
	for _, m := range offering {
		if m.Online {
			online = append(online, m)
		}
	}
	if len(online) == 1 {
		return online[0], ""
	}
	return machine{}, fmt.Sprintf("Several machines offer %s: %s. Name one with machine.", tool, list(offering, now))
}

// list names machines with their kind and whether they're online.
func list(ms []machine, now time.Time) string {
	parts := make([]string, len(ms))
	for i, m := range ms {
		parts[i] = fmt.Sprintf("%s (%s, %s)", m.Device.Name, kindWord(m.Device.Kind), onlineWord(m, now))
	}
	return strings.Join(parts, ", ")
}

// machinesResult answers the machines tool, as text only: with structured content present,
// Claude's apps show that instead of the text (live check 2026-10-22, .claude/rules/macos.md).
func machinesResult(ms []machine, now time.Time) *mcp.CallToolResult {
	var b strings.Builder
	if len(ms) == 1 {
		b.WriteString("Your machine:\n")
	} else {
		fmt.Fprintf(&b, "Your machines (%d):\n", len(ms))
	}
	for _, m := range ms {
		var tools []string
		for _, t := range m.Tools {
			tools = append(tools, t.Name)
		}
		fmt.Fprintf(&b, "- %s · %s", m.Device.Name, kindPhrase(m.Device.Kind))
		if m.Device.OSVersion != "" {
			if m.Device.Kind == store.KindMac {
				fmt.Fprintf(&b, " (macOS %s)", m.Device.OSVersion)
			} else {
				fmt.Fprintf(&b, " (%s)", m.Device.OSVersion)
			}
		}
		if m.Online {
			line := statusLine(m.Device.Name, m.Device.Kind, m.State)
			b.WriteString(" · " + strings.TrimPrefix(line, fmt.Sprintf("%s (%s): ", m.Device.Name, kindWord(m.Device.Kind))))
		} else {
			b.WriteString(" · " + onlineWord(m, now))
		}
		if len(tools) == 0 {
			b.WriteString(" · offers no tools (all turned off on it)\n")
		} else {
			b.WriteString(" · offers: " + strings.Join(tools, ", ") + "\n")
		}
	}
	if len(ms) > 1 {
		b.WriteString("Pass a machine's name as machine when more than one offers a tool.")
	}
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: strings.TrimRight(b.String(), "\n")}}}
}

// instructions is what the relay tells Claude's apps at initialize (plan "How Claude uses it");
// every rule in it is in the tool descriptions too, since not every app shows it to Claude.
const instructions = "Latchkey reaches the owner's own machines: Macs and Linux servers. " +
	"The machines tool lists them, whether each is online, and what each offers. " +
	"When more than one machine offers a tool, pass the machine's name as machine; when only one does, leave it out. " +
	"Every answer ends with the answering machine's state and the other machines."

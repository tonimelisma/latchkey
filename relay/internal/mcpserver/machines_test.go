package mcpserver

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/agentproto"
)

func shellTool(desc string, props map[string]any, required ...any) *mcp.Tool {
	schema := map[string]any{"type": "object", "properties": props}
	if len(required) > 0 {
		schema["required"] = required
	}
	return &mcp.Tool{
		Name: "shell_run", Title: "Run a Command", Description: desc, InputSchema: schema,
		Annotations: &mcp.ToolAnnotations{DestructiveHint: ptr(true), OpenWorldHint: ptr(true)},
		Meta:        mcp.Meta{"latchkey/deadline_ms": 45000.0},
	}
}

func schemaOf(t *testing.T, tool *mcp.Tool) map[string]any {
	t.Helper()
	m, ok := toMap(tool.InputSchema)
	require.True(t, ok)
	return m
}

func props(t *testing.T, tool *mcp.Tool) map[string]any {
	t.Helper()
	p, _ := schemaOf(t, tool)["properties"].(map[string]any)
	return p
}

func TestMergedToolsOneKind(t *testing.T) {
	macShell := shellTool("Runs a command on the Mac (zsh).", map[string]any{
		"command": map[string]any{"type": "string", "description": "The command line"},
	}, "command")
	ms := []machine{
		{Device: mac("A"), Tools: []*mcp.Tool{macShell}},
		{Device: mac("B"), Tools: []*mcp.Tool{macShell, {Name: "notes_find", InputSchema: map[string]any{"type": "object"}}}},
	}
	tools := mergedTools(ms)
	names := []string{}
	for _, tool := range tools {
		names = append(names, tool.Name)
	}
	assert.Equal(t, []string{"machines", "notes_find", "shell_run"}, names, "the machines tool, then each name once")
	shell := tools[2]
	assert.Equal(t, "Runs a command on the Mac (zsh).", shell.Description, "one kind: its description as is")
	assert.Equal(t, map[string]any{"type": "string", "description": machineArgDescription}, props(t, shell)["machine"])
	assert.Equal(t, []any{"command"}, schemaOf(t, shell)["required"], "machine is never required")
	_, hasMachine := props(t, ms[0].Tools[0])["machine"]
	assert.False(t, hasMachine, "the machine's own definition is left alone")
	notes := tools[1]
	assert.Contains(t, props(t, notes), "machine", "a tool without properties gets the machine argument too")

	assert.Nil(t, mergedTools(nil), "nothing paired: no tools at all, not even machines")
}

// Toni, 2026-10-31: one tool, with a part per kind of machine and the options only one kind has
// marked as such (plan D2).
func TestMergedToolsPerKindNotes(t *testing.T) {
	macShell := shellTool("Runs a command in zsh, never as administrator.", map[string]any{
		"command": map[string]any{"type": "string", "description": "The command line"},
		"writes":  map[string]any{"type": "array", "description": "Folders the command will write"},
	}, "command")
	linuxShell := shellTool("Runs a command in bash; sudo works where allowed without a password.", map[string]any{
		"command": map[string]any{"type": "string", "description": "The command line"},
	}, "command")
	linuxShell.Meta["latchkey/deadline_ms"] = 50000.0
	linuxShell.Annotations.ReadOnlyHint = false
	macFiles := &mcp.Tool{Name: "files_change", Description: "Changes files on the Mac.", InputSchema: map[string]any{
		"type": "object", "required": []any{"action", "path"}, "properties": map[string]any{
			"action": map[string]any{"type": "string", "enum": []any{"write", "trash"}},
			"path":   map[string]any{"type": "string"},
		},
	}}
	linuxFiles := &mcp.Tool{Name: "files_change", Description: "Changes files on the server; delete removes for good.", InputSchema: map[string]any{
		"type": "object", "required": []any{"action"}, "properties": map[string]any{
			"action": map[string]any{"type": "string", "enum": []any{"write", "delete"}},
			"path":   map[string]any{"type": "string"},
		},
	}}
	old := now.Add(-time.Hour)
	ms := []machine{
		{Device: linux("homeserver"), LastSeen: now, Tools: []*mcp.Tool{linuxShell, linuxFiles}},
		{Device: mac("Old Mac"), LastSeen: old, Tools: []*mcp.Tool{shellTool("an older app's text", nil)}},
		{Device: mac("New Mac"), LastSeen: now, Tools: []*mcp.Tool{macShell, macFiles}},
	}
	tools := mergedTools(ms)
	require.Len(t, tools, 3)
	files, shell := tools[1], tools[2]

	assert.Equal(t, "On a Mac: Runs a command in zsh, never as administrator.\n\n"+
		"On a Linux server: Runs a command in bash; sudo works where allowed without a password.", shell.Description,
		"Mac first, each kind from its most recently seen machine")
	p := props(t, shell)
	assert.Equal(t, "Folders the command will write (Mac only)", p["writes"].(map[string]any)["description"])
	assert.Equal(t, "The command line", p["command"].(map[string]any)["description"], "a shared option isn't marked")
	assert.Contains(t, p, "machine")
	assert.Equal(t, []any{"command"}, schemaOf(t, shell)["required"])
	assert.Equal(t, 50*time.Second, agentproto.ToolDeadline(shell), "the longest deadline")
	require.NotNil(t, shell.Annotations)
	assert.True(t, *shell.Annotations.DestructiveHint)

	fp := props(t, files)
	assert.Equal(t, []any{"write", "trash", "delete"}, fp["action"].(map[string]any)["enum"], "enum values united")
	assert.Equal(t, []any{"action"}, schemaOf(t, files)["required"], "required only what both require")
	assert.Contains(t, files.Description, "On a Linux server: Changes files on the server; delete removes for good.")
}

func TestTakeMachine(t *testing.T) {
	name, rest := takeMachine(json.RawMessage(`{"machine":" homeserver ","command":"df -h"}`))
	assert.Equal(t, "homeserver", name)
	assert.JSONEq(t, `{"command":"df -h"}`, string(rest), "the machine never sees it")

	name, rest = takeMachine(json.RawMessage(`{"command":"df -h"}`))
	assert.Empty(t, name)
	assert.JSONEq(t, `{"command":"df -h"}`, string(rest))

	name, rest = takeMachine(nil)
	assert.Empty(t, name)
	assert.Nil(t, rest)
}

func TestChooseMachine(t *testing.T) {
	shell := &mcp.Tool{Name: "shell_run"}
	notes := &mcp.Tool{Name: "notes_find"}
	theMac := machine{Device: mac("Toni's MacBook Pro"), Online: true, Tools: []*mcp.Tool{shell, notes}}
	server := machine{Device: linux("homeserver"), Online: true, Tools: []*mcp.Tool{shell}}
	offServer := server
	offServer.Online, offServer.LastSeen = false, now.Add(-2*time.Hour)
	bare := machine{Device: linux("nas"), Online: true} // everything turned off

	pick := func(ms []machine, tool, named string) (string, string) {
		m, refusal := choose(ms, tool, named, now)
		return m.Device.Name, refusal
	}

	// Named, case and spaces aside.
	got, refusal := pick([]machine{theMac, server}, "shell_run", "HomeServer")
	assert.Equal(t, "homeserver", got)
	assert.Empty(t, refusal)

	// Not named: the only machine that offers it, online or not (its offline answer comes at once).
	got, _ = pick([]machine{theMac, server}, "notes_find", "")
	assert.Equal(t, "Toni's MacBook Pro", got)
	got, _ = pick([]machine{offServer}, "shell_run", "")
	assert.Equal(t, "homeserver", got)

	// Not named, several offer it, one online: that one.
	got, _ = pick([]machine{theMac, offServer}, "shell_run", "")
	assert.Equal(t, "Toni's MacBook Pro", got)

	// Not named, several online: no guess.
	_, refusal = pick([]machine{theMac, server}, "shell_run", "")
	assert.Equal(t, "Several machines offer shell_run: Toni's MacBook Pro (Mac, online), homeserver (Linux, online). Name one with machine.", refusal)

	// Unknown name.
	_, refusal = pick([]machine{theMac, offServer}, "shell_run", "pi")
	assert.Equal(t, `No machine is called "pi". Your machines: Toni's MacBook Pro (Mac, online), homeserver (Linux, offline, last seen 2 hours ago).`, refusal)

	// A machine that doesn't offer the tool: as if it didn't exist there (Constitution III).
	_, refusal = pick([]machine{theMac, server}, "notes_find", "homeserver")
	assert.Equal(t, "homeserver doesn't offer notes_find. It's offered by: Toni's MacBook Pro (Mac, online).", refusal)
	_, refusal = pick([]machine{bare}, "shell_run", "nas")
	assert.Equal(t, "No machine offers shell_run.", refusal)
	_, refusal = pick([]machine{bare}, "shell_run", "")
	assert.Equal(t, "No machine offers shell_run.", refusal)
}

func TestMachinesResult(t *testing.T) {
	up := int64(3 * 24 * 3600)
	ms := []machine{
		{Device: mac("Toni's MacBook Pro"), Online: true, State: lastState(64, "battery"), Tools: []*mcp.Tool{{Name: "shell_run"}, {Name: "notes_find"}}},
		{Device: linux("homeserver"), Online: true, State: &agentproto.State{UptimeS: &up}, Tools: []*mcp.Tool{{Name: "shell_run"}}},
		{Device: linux("nas"), LastSeen: now.Add(-time.Hour)},
	}
	ms[0].Device.OSVersion = "26.1"
	ms[1].Device.OSVersion = "Ubuntu 24.04.1 LTS"
	res := machinesResult(ms, now)
	text := res.Content[0].(*mcp.TextContent).Text
	assert.Equal(t, "Your machines (3):\n"+
		"- Toni's MacBook Pro · Mac (macOS 26.1) · online · 64% battery, on battery power · keep-awake on · offers: shell_run, notes_find\n"+
		"- homeserver · Linux server (Ubuntu 24.04.1 LTS) · online · up 3 days · offers: shell_run\n"+
		"- nas · Linux server · offline, last seen 1 hour ago · offers no tools (all turned off on it)\n"+
		"Pass a machine's name as machine when more than one offers a tool.", text)
	assert.Nil(t, res.StructuredContent, "text only: Claude's apps would show structured content instead of the text")
}

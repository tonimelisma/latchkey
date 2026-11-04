package latchkeylog_test

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/linux/internal/activity"
	"github.com/tonimelisma/latchkey/linux/internal/latchkeylog"
	"github.com/tonimelisma/latchkey/linux/internal/tools"
	"github.com/tonimelisma/latchkey/relay/agentproto"
)

var zone = time.FixedZone("Test/Zone", -8*3600)

func text(t *testing.T, r tools.Result) string {
	t.Helper()
	require.Len(t, r.Content, 1)
	s, _ := r.Content[0]["text"].(string)
	return s
}

func setup(t *testing.T) (*activity.Log, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "activity.jsonl")
	log, err := activity.Open(path)
	require.NoError(t, err)
	return log, path
}

func TestDefinition(t *testing.T) {
	log, path := setup(t)
	d := latchkeylog.New(log, path, "0.1.1", zone).Def
	assert.Equal(t, "latchkey_log", d.Name)
	assert.True(t, d.Annotations.ReadOnlyHint)
	assert.InDelta(t, 10000, d.Meta[agentproto.DeadlineMetaKey], 0, "deadline 10 s")
	schema, _ := d.InputSchema.(map[string]any)
	props, _ := schema["properties"].(map[string]any)
	lines, _ := props["lines"].(map[string]any)
	category, _ := props["category"].(map[string]any)
	assert.Equal(t, "integer", lines["type"])
	assert.Equal(t, []any{"app", "connection", "pairing", "settings", "pause", "update", "audit"}, category["enum"])
	assert.Nil(t, schema["required"], "both arguments are optional")
	assert.Contains(t, d.Description, "no tool calls, commands, file names, or the relay's address")
}

func TestAnswer(t *testing.T) {
	log, path := setup(t)
	at := time.Date(2026, 11, 3, 22, 2, 9, 0, time.UTC)
	add := func(e activity.Entry) { require.NoError(t, log.Add(e)) }
	add(activity.Entry{At: at, Kind: "event", Category: "app", Text: "Latchkey 0.1.1 started", Public: "Latchkey 0.1.1 started"})
	add(activity.Entry{At: at.Add(time.Second), Kind: "call", Tool: "shell_run", Arguments: `{"command":"cat /etc/shadow"}`, Result: "secret"})
	add(activity.Entry{At: at.Add(2 * time.Second), Kind: "event", Category: "connection", IsError: true, Text: "Disconnected: dial tcp 10.0.0.1:443", Public: "Disconnected: the relay refused the connection;\ntrying again in 2s"})
	add(activity.Entry{At: at.Add(4 * time.Second), Kind: "event", Category: "connection", Text: `Connected to https://relay.example as "box"`, Public: `Connected as "box"`})
	add(activity.Entry{At: at.Add(5 * time.Second), Kind: "event", Category: "audit", Text: "Audit check: call_1 missing"})
	tool := latchkeylog.New(log, path, "0.1.1", zone)

	r := tool.Run(context.Background(), tools.Args{})
	assert.False(t, r.IsError)
	assert.Equal(t, `Latchkey's own log on this server (Latchkey 0.1.1): the newest 3 lines, newest last; times in Test/Zone (UTC-08:00).
2026-11-03 14:02:09 app: Latchkey 0.1.1 started
2026-11-03 14:02:11 connection ERROR: Disconnected: the relay refused the connection; trying again in 2s
2026-11-03 14:02:13 connection: Connected as "box"`, text(t, r))
	for _, private := range []string{"shadow", "secret", "relay.example", "10.0.0.1", "call_1"} {
		assert.NotContains(t, text(t, r), private, "FR-1053")
	}

	r = tool.Run(context.Background(), tools.Args{"category": "connection", "lines": float64(1)})
	assert.Equal(t, `Latchkey's own connection log on this server (Latchkey 0.1.1): the newest 1 lines, newest last; times in Test/Zone (UTC-08:00).
2026-11-03 14:02:13 connection: Connected as "box"`, text(t, r))

	r = tool.Run(context.Background(), tools.Args{"category": "pause"})
	assert.Equal(t, "Latchkey's log on this server has no pause lines yet.", text(t, r))
}

func TestEmpty(t *testing.T) {
	log, path := setup(t)
	r := latchkeylog.New(log, path, "0.1.1", zone).Run(context.Background(), tools.Args{})
	assert.Equal(t, "Latchkey's log on this server has no lines yet.", text(t, r))
}

func TestBadArguments(t *testing.T) {
	log, path := setup(t)
	tool := latchkeylog.New(log, path, "0.1.1", zone)
	for _, v := range []any{float64(0), float64(1001), 2.5, "ten"} {
		r := tool.Run(context.Background(), tools.Args{"lines": v})
		assert.True(t, r.IsError)
		assert.Equal(t, "lines must be a whole number from 1 to 1000.", text(t, r))
	}
	r := tool.Run(context.Background(), tools.Args{"category": "x"})
	assert.True(t, r.IsError)
	assert.Equal(t, `category must be one of: app, connection, pairing, settings, pause, update, audit (got "x").`, text(t, r))
	r = tool.Run(context.Background(), tools.Args{"category": float64(3)})
	assert.True(t, r.IsError)
	assert.Equal(t, "category must be one of: app, connection, pairing, settings, pause, update, audit.", text(t, r))
}

func TestFromMemoryWhenTheLogCantBeRead(t *testing.T) {
	log, path := setup(t)
	log.Event("app", "Latchkey %s started", "0.1.1")
	require.NoError(t, os.Remove(path))
	require.NoError(t, os.Mkdir(path, 0o700)) // the log is now a folder: unreadable as a file
	r := latchkeylog.New(log, path, "0.1.1", zone).Run(context.Background(), tools.Args{})
	got := text(t, r)
	assert.False(t, r.IsError)
	assert.Contains(t, got, "Latchkey's activity log isn't available just now (it is a folder), ")
	assert.Contains(t, got, "so these are only the lines since Latchkey started.")
	assert.Contains(t, got, "app: Latchkey 0.1.1 started")
	assert.NotContains(t, got, path, "the reason names no file (FR-1053)")
}

func TestLongAnswersLeaveOutTheOldest(t *testing.T) {
	log, path := setup(t)
	for i := range 1000 {
		log.Event("app", "line %04d %s", i, strings.Repeat("x", 100))
	}
	log.Event("app", "long %s", strings.Repeat("y\n", 3000))
	r := latchkeylog.New(log, path, "0.1.1", zone).Run(context.Background(), tools.Args{"lines": float64(1000)})
	got := text(t, r)
	assert.LessOrEqual(t, len([]rune(got)), 40000)
	lines := strings.Split(got, "\n")
	assert.Regexp(t, `^\d+ older lines left out to keep the answer short; ask for fewer lines or one category\.$`, lines[len(lines)-1])
	newest := lines[len(lines)-2]
	assert.Contains(t, newest, "app: long y y y", "a line break becomes a space")
	assert.True(t, strings.HasSuffix(newest, "…"), "one line is cut at 2000 characters")
	assert.Contains(t, got, fmt.Sprintf("line %04d", 998))
	assert.NotContains(t, got, "line 0000 ")
}

func TestZoneName(t *testing.T) {
	la := time.FixedZone("America/Los_Angeles", -7*3600)
	assert.Equal(t, "America/Los_Angeles", latchkeylog.ZoneName(la, "", ""))
	assert.Equal(t, "Europe/Helsinki", latchkeylog.ZoneName(time.Local, ":Europe/Helsinki", ""), "TZ first")
	assert.Equal(t, "Etc/UTC", latchkeylog.ZoneName(time.Local, "", "/usr/share/zoneinfo/Etc/UTC"), "then /etc/localtime's target")
	assert.NotEmpty(t, latchkeylog.ZoneName(time.Local, "", ""), "else the abbreviation")
}

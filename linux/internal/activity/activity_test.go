package activity_test

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/linux/internal/activity"
)

func TestLogIsPrivateAndReadable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "data", "activity.jsonl")
	log, err := activity.Open(path)
	require.NoError(t, err)
	info, err := os.Stat(path)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm(), "only the Owner reads it (FR-1051)")

	t0 := time.Date(2026, 10, 31, 12, 0, 0, 0, time.UTC)
	require.NoError(t, log.Add(activity.Entry{At: t0, Kind: "call", CallID: "call_1", Tool: "shell_run", Client: "Claude", Arguments: `{"command":"df -h"}`, Result: strings.Repeat("x", 5000), DurationMS: 12}))
	log.Private("connection", false, "Connected to https://relay.example", "Connected")
	entries, err := activity.Read(path, t0)
	require.NoError(t, err)
	require.Len(t, entries, 2)
	assert.Len(t, []rune(entries[0].Result), 2001, "long results are cut")
	var out bytes.Buffer
	activity.Print(&out, entries, 50)
	assert.Contains(t, out.String(), `shell_run from Claude (ok, 12 ms) {"command":"df -h"}`)
	assert.Contains(t, out.String(), "Connected to https://relay.example")

	later, err := activity.Read(path, t0.Add(time.Hour*24*365*10))
	require.NoError(t, err)
	assert.Empty(t, later)
}

func TestCompareWithTheRelay(t *testing.T) {
	log := []activity.Entry{{Kind: "call", CallID: "a"}, {Kind: "call", CallID: "b"}, {Kind: "call", CallID: "local-only"}, {Kind: "event"}}
	relay := []activity.RelayEntry{{CallID: "a", Outcome: "ok"}, {CallID: "b", Outcome: "error"}, {CallID: "never-reached", Outcome: "offline"}, {CallID: "lost", Outcome: "ok"}, {CallID: "running", Outcome: "ok"}, {CallID: ""}}
	missingHere, missingThere := activity.Compare(log, relay, map[string]bool{"running": true})
	assert.Equal(t, []string{"lost"}, missingHere, "offline calls never reached the server; running ones aren't done")
	assert.Equal(t, []string{"local-only"}, missingThere)
}

func TestPublicEventsForClaude(t *testing.T) {
	path := filepath.Join(t.TempDir(), "activity.jsonl")
	// A line from before the mark: an event with no public words.
	require.NoError(t, os.WriteFile(path, []byte(`{"at":"2026-11-01T00:00:00Z","kind":"event","text":"Connected to https://relay.example as \"old\""}`+"\n"), 0o600))
	log, err := activity.Open(path)
	require.NoError(t, err)
	require.NoError(t, log.Add(activity.Entry{Kind: "call", CallID: "c1", Tool: "shell_run", Arguments: `{"command":"cat secret"}`, Public: "never shown"}))
	log.Event("app", "Latchkey %s started", "0.1.1")
	log.Private("connection", false, "Connected to https://relay.example as \"box\"", "Connected as \"box\"")
	log.Private("audit", true, "Audit check: 1 call missing (call_9)", "")
	log.Problem("connection", "Disconnected: %s", "the connection dropped")

	all, err := activity.Public(path, "", 10)
	require.NoError(t, err)
	var words []string
	for _, e := range all {
		words = append(words, e.Category+": "+e.Public)
	}
	assert.Equal(t, []string{"app: Latchkey 0.1.1 started", `connection: Connected as "box"`, "connection: Disconnected: the connection dropped"}, words,
		"oldest first; no calls, nothing from before the mark, nothing without public words (FR-1053)")
	assert.True(t, all[2].IsError)

	last, err := activity.Public(path, "connection", 1)
	require.NoError(t, err)
	require.Len(t, last, 1)
	assert.Equal(t, "Disconnected: the connection dropped", last[0].Public, "the newest of one category")

	mem := log.Recent("app", 10)
	require.Len(t, mem, 1, "this run's public events in memory (FR-1055)")
	assert.Equal(t, "Latchkey 0.1.1 started", mem[0].Public)
	assert.Len(t, log.Recent("", 2), 2)

	entries, err := activity.Read(path, time.Time{})
	require.NoError(t, err)
	var owner bytes.Buffer
	activity.Print(&owner, entries, 50)
	assert.Contains(t, owner.String(), "Audit check: 1 call missing (call_9)", "the Owner still sees the private words")
	assert.Contains(t, owner.String(), `Connected to https://relay.example as "box"`)
}

func TestMemoryKeepsTheNewest1000(t *testing.T) {
	log, err := activity.Open(filepath.Join(t.TempDir(), "activity.jsonl"))
	require.NoError(t, err)
	for i := range 1005 {
		log.Event("app", "line %d", i)
	}
	mem := log.Recent("", 5000)
	require.Len(t, mem, 1000)
	assert.Equal(t, "line 5", mem[0].Public)
	assert.Equal(t, "line 1004", mem[999].Public)
}

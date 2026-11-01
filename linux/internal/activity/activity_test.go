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
	log.Event("Connected to %s", "https://relay.example")
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

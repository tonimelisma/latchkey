package activity_test

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/linux/internal/activity"
)

// files is a log's place in a fresh data folder: the daily files' folder and the old single file.
func files(t *testing.T) activity.Files {
	t.Helper()
	data := filepath.Join(t.TempDir(), "data")
	return activity.Files{Dir: filepath.Join(data, "activity"), Old: filepath.Join(data, "activity.jsonl")}
}

func open(t *testing.T, f activity.Files) *activity.Log {
	t.Helper()
	log, err := activity.Open(f)
	require.NoError(t, err)
	return log
}

func lines(t *testing.T, path string) []map[string]json.RawMessage {
	t.Helper()
	data, err := os.ReadFile(path) //nolint:gosec // a test's own file
	require.NoError(t, err)
	require.True(t, bytes.HasSuffix(data, []byte("\n")), "every line ends with a line break")
	var out []map[string]json.RawMessage
	for _, l := range bytes.Split(bytes.TrimSuffix(data, []byte("\n")), []byte("\n")) {
		var m map[string]json.RawMessage
		require.NoError(t, json.Unmarshal(l, &m), "%s", l)
		out = append(out, m)
	}
	return out
}

// One file a day, private, every call whole (FR-1057; trace-files.md "Linux server").
func TestDailyFilesArePrivateAndKeepEverythingWhole(t *testing.T) {
	f := files(t)
	log := open(t, f)
	info, err := os.Stat(f.Dir)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o700), info.Mode().Perm(), "the folder is the Owner's only")
	_, err = os.Stat(f.Old)
	require.ErrorIs(t, err, os.ErrNotExist, "the single file of earlier versions is never made again")

	at := time.Date(2026, 11, 15, 23, 59, 59, 500_000_000, time.UTC)
	big := strings.Repeat("x", 1<<20)
	result, err := json.Marshal([]map[string]string{{"type": "text", "text": big}, {"type": "image", "data": "iVBORw0KGgo=", "mimeType": "image/png"}})
	require.NoError(t, err)
	args := json.RawMessage(`{"command":"df -h","note":"<b>&</b>"}`)
	require.NoError(t, log.Add(activity.Entry{At: at, Kind: "call", CallID: "call_1", Tool: "shell_run", Client: "Claude", Arguments: args, Result: result, DurationMS: 12}))
	log.Private("connection", false, "Connected to https://relay.example as \"box\"", `Connected as "box"`)

	day := filepath.Join(f.Dir, "2026-11-15.jsonl")
	info, err = os.Stat(day)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm(), "only the Owner reads it (FR-1051)")
	got := lines(t, day)
	require.Len(t, got, 1, "the event of today is in today's file")
	call := got[0]
	assert.JSONEq(t, `1`, string(call["v"]))
	assert.JSONEq(t, `"2026-11-15T23:59:59.500Z"`, string(call["at"]), "RFC 3339 UTC with milliseconds")
	assert.JSONEq(t, `"call"`, string(call["kind"]))
	assert.JSONEq(t, `"call_1"`, string(call["call_id"]))
	assert.JSONEq(t, `"shell_run"`, string(call["tool"]))
	assert.JSONEq(t, `"Claude"`, string(call["client"]))
	assert.JSONEq(t, string(args), string(call["arguments"]), "the arguments as they came, as JSON")
	assert.Contains(t, string(call["arguments"]), "<b>&</b>", "nothing escaped either")
	assert.JSONEq(t, string(result), string(call["result"]), "the whole content array, 1 MB of text and the image")
	assert.Greater(t, len(call["result"]), 1<<20)
	assert.JSONEq(t, `12`, string(call["duration_ms"]))

	today := lines(t, filepath.Join(f.Dir, time.Now().UTC().Format("2006-01-02")+".jsonl"))
	event := today[len(today)-1]
	assert.JSONEq(t, `1`, string(event["v"]))
	assert.JSONEq(t, `"event"`, string(event["kind"]))
	assert.JSONEq(t, `"connection"`, string(event["category"]))
	assert.JSONEq(t, `"Connected to https://relay.example as \"box\""`, string(event["text"]))
	assert.JSONEq(t, `"Connected as \"box\""`, string(event["public"]))
	assert.NotContains(t, event, "arguments")

	entries, skipped, err := f.Newest(10, nil)
	require.NoError(t, err)
	assert.Zero(t, skipped)
	require.Len(t, entries, 2)
	assert.Equal(t, 1, entries[0].V)
	assert.Equal(t, at, entries[0].At)
	assert.JSONEq(t, string(result), string(entries[0].Result))
	var out bytes.Buffer
	activity.Print(&out, entries, 50)
	assert.Contains(t, out.String(), `shell_run from Claude (ok, 12 ms) {"command":"df -h","note":"<b>&</b>"}`)
	assert.Contains(t, out.String(), `Connected to https://relay.example as "box"`)
}

// An entry is filed under the UTC day of its time, whatever the server's zone.
func TestTheDayIsTheUTCDay(t *testing.T) {
	f := files(t)
	log := open(t, f)
	pacific := time.FixedZone("PST", -8*3600)
	require.NoError(t, log.Add(activity.Entry{At: time.Date(2026, 11, 15, 23, 30, 0, 0, pacific), Kind: "call", CallID: "late", Tool: "shell_run"}))
	require.NoError(t, log.Add(activity.Entry{At: time.Date(2026, 11, 16, 0, 0, 0, 0, time.UTC).Add(-time.Millisecond), Kind: "call", CallID: "edge", Tool: "shell_run"}))
	require.NoError(t, log.Add(activity.Entry{At: time.Date(2026, 11, 16, 0, 0, 0, 0, time.UTC), Kind: "call", CallID: "midnight", Tool: "shell_run"}))
	ids := func(day string) []string {
		var out []string
		for _, l := range lines(t, filepath.Join(f.Dir, day+".jsonl")) {
			var id string
			require.NoError(t, json.Unmarshal(l["call_id"], &id))
			out = append(out, id)
		}
		return out
	}
	assert.Equal(t, []string{"edge"}, ids("2026-11-15"))
	assert.Equal(t, []string{"late", "midnight"}, ids("2026-11-16"), "23:30 in UTC-8 is 07:30 the next day in UTC")
	got := lines(t, filepath.Join(f.Dir, "2026-11-16.jsonl"))
	assert.JSONEq(t, `"2026-11-16T07:30:00.000Z"`, string(got[0]["at"]))
}

// The log of earlier versions: read as version 0, never changed; lines that can't be read are
// skipped and counted, in either kind of file (FR-1058; trace-files.md "Rules on every side").
func TestOldFileAndBadLines(t *testing.T) {
	f := files(t)
	require.NoError(t, os.MkdirAll(filepath.Dir(f.Old), 0o700))
	old := `{"at":"2026-11-01T10:00:00Z","kind":"call","call_id":"old_1","tool":"shell_run","client":"Claude","arguments":"{\"command\":\"ls\"}","result":"a\nb","duration_ms":5}
{"at":"2026-11-01T10:00:01Z","kind":"event","category":"app","text":"Latchkey 0.1.1 started","public":"Latchkey 0.1.1 started"}
{"at":"2026-11-01T10:00:02Z","kind":"call","call_id":"old_2","tool":"shell_r
{"v":7,"at":"2026-11-01T10:00:03Z","kind":"call","call_id":"future"}
` + "\n"
	require.NoError(t, os.WriteFile(f.Old, []byte(old), 0o600))
	stamp := time.Date(2026, 11, 2, 0, 0, 0, 0, time.UTC)
	require.NoError(t, os.Chtimes(f.Old, stamp, stamp))
	log := open(t, f)
	// A day file whose last write was cut short (a crash, a full disk): no line break at its end.
	day := filepath.Join(f.Dir, "2026-11-15.jsonl")
	require.NoError(t, os.WriteFile(day, []byte(`{"v":1,"at":"2026-11-15T08:00:00.000Z","kind":"call","call_id":"new_1","tool":"files_read","arguments":{"path":"/etc/hosts"},"result":[{"type":"text","text":"127.0.0.1"}]}`+"\n"+`{"v":1,"at":"2026-11-15T08:00:01.000Z","kind":"ca`), 0o600))
	require.NoError(t, log.Add(activity.Entry{At: time.Date(2026, 11, 15, 9, 0, 0, 0, time.UTC), Kind: "call", CallID: "new_2", Tool: "shell_run", Arguments: json.RawMessage(`{}`), Result: json.RawMessage(`[]`)}))

	data, err := os.ReadFile(f.Old)
	require.NoError(t, err)
	assert.Equal(t, old, string(data), "the old file is never changed")
	info, err := os.Stat(f.Old)
	require.NoError(t, err)
	assert.Equal(t, stamp, info.ModTime().UTC(), "nor written to")

	entries, skipped, err := f.Newest(100, nil)
	require.NoError(t, err)
	assert.Equal(t, 3, skipped, "the cut-off old line, the unknown version, the cut-off new line")
	var ids []string
	for _, e := range entries {
		ids = append(ids, e.CallID+"/"+e.Kind)
	}
	assert.Equal(t, []string{"old_1/call", "/event", "new_1/call", "new_2/call"}, ids, "oldest first, both files")
	assert.Equal(t, 0, entries[0].V)
	assert.JSONEq(t, `{"command":"ls"}`, entries[0].ArgumentsText(), "version 0's arguments are text")
	assert.JSONEq(t, `{"path":"/etc/hosts"}`, entries[2].ArgumentsText())

	calls, skipped, err := f.Calls(time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Equal(t, 3, skipped)
	ids = nil
	for _, e := range calls {
		ids = append(ids, e.CallID)
	}
	assert.Equal(t, []string{"old_1", "new_1", "new_2"}, ids, "the comparison reads both files")

	last, _, err := f.Newest(1, nil)
	require.NoError(t, err)
	require.Len(t, last, 1)
	assert.Equal(t, "new_2", last[0].CallID, "the line after a cut-off one is read whole")
}

// A line cut short by a crash costs only that line: the next entry starts on a line of its own
// (a "\n" first), and nothing before it changes (trace-files.md "Rules on every side").
func TestACutShortLineNeverRunsIntoTheNext(t *testing.T) {
	f := files(t)
	log := open(t, f)
	at := time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC)
	require.NoError(t, log.Add(activity.Entry{At: at, Kind: "call", CallID: "before", Tool: "shell_run"}))
	day := filepath.Join(f.Dir, "2026-11-15.jsonl")
	file, err := os.OpenFile(day, os.O_APPEND|os.O_WRONLY, 0o600) //nolint:gosec // a test's own file
	require.NoError(t, err)
	_, err = file.WriteString(`{"v":1,"at":"2026-11-15T10:00:01.000Z","kind":"call","call_id":"cut","resu`)
	require.NoError(t, err)
	require.NoError(t, file.Close())
	earlier, err := os.ReadFile(day) //nolint:gosec // a test's own file
	require.NoError(t, err)

	require.NoError(t, log.Add(activity.Entry{At: at.Add(2 * time.Second), Kind: "call", CallID: "after", Tool: "shell_run"}))
	now, err := os.ReadFile(day) //nolint:gosec // a test's own file
	require.NoError(t, err)
	require.True(t, bytes.HasPrefix(now, earlier), "the bytes already there are unchanged")
	assert.Equal(t, byte('\n'), now[len(earlier)], "a line break first")
	assert.Equal(t, 3, bytes.Count(now, []byte("\n")))

	entries, skipped, err := f.Newest(10, nil)
	require.NoError(t, err)
	assert.Equal(t, 1, skipped, "the cut-short line, skipped and counted")
	require.Len(t, entries, 2)
	assert.Equal(t, "before", entries[0].CallID)
	assert.Equal(t, "after", entries[1].CallID, "the new entry reads whole")

	require.NoError(t, log.Add(activity.Entry{At: at.Add(3 * time.Second), Kind: "call", CallID: "next", Tool: "shell_run"}))
	again, err := os.ReadFile(day) //nolint:gosec // a test's own file
	require.NoError(t, err)
	assert.Equal(t, 4, bytes.Count(again, []byte("\n")), "no extra line break after a whole line")
}

// The comparison asks for a time range: only those days' files are opened, and the old file.
func TestCallsReadOnlyTheDaysAsked(t *testing.T) {
	f := files(t)
	log := open(t, f)
	for _, d := range []int{10, 12, 14} {
		require.NoError(t, log.Add(activity.Entry{At: time.Date(2026, 11, d, 12, 0, 0, 0, time.UTC), Kind: "call", CallID: "day" + string(rune('0'+d-10)), Tool: "shell_run"}))
	}
	require.NoError(t, log.Add(activity.Entry{At: time.Date(2026, 11, 12, 13, 0, 0, 0, time.UTC), Kind: "event", Text: "x", Public: "x"}))
	// Days outside the range that couldn't be read at all.
	require.NoError(t, os.Mkdir(filepath.Join(f.Dir, "2026-11-09.jsonl"), 0o700))
	require.NoError(t, os.Mkdir(filepath.Join(f.Dir, "2026-11-15.jsonl"), 0o700))
	calls, _, err := f.Calls(time.Date(2026, 11, 10, 12, 0, 0, 1, time.UTC), time.Date(2026, 11, 14, 11, 0, 0, 0, time.UTC))
	require.NoError(t, err, "the unreadable days aren't opened")
	require.Len(t, calls, 1, "only calls, only in the range")
	assert.Equal(t, "day2", calls[0].CallID)
	_, _, err = f.Calls(time.Time{}, time.Time{})
	assert.Error(t, err, "a day that can't be read is an error")
}

func TestNothingYet(t *testing.T) {
	f := activity.Files{Dir: filepath.Join(t.TempDir(), "activity"), Old: filepath.Join(t.TempDir(), "activity.jsonl")}
	_, _, err := f.Newest(10, nil)
	require.ErrorIs(t, err, os.ErrNotExist)
	_, err = f.Public("", 10)
	require.ErrorIs(t, err, os.ErrNotExist)
}

// A write that fails never fails the call: Add says so and nothing else happens.
func TestAFailedWriteIsOnlyAnError(t *testing.T) {
	f := files(t)
	log := open(t, f)
	require.NoError(t, os.RemoveAll(f.Dir))
	require.NoError(t, os.WriteFile(f.Dir, nil, 0o600)) // the folder is now a file
	require.Error(t, log.Add(activity.Entry{Kind: "call", CallID: "c", Tool: "shell_run"}))
	log.Event("app", "still recorded in memory")
	assert.Len(t, log.Recent("", 10), 1)
}

func TestCompareWithTheRelay(t *testing.T) {
	log := []activity.Entry{{Kind: "call", CallID: "a"}, {Kind: "call", CallID: "b"}, {Kind: "call", CallID: "local-only"}, {Kind: "event"}}
	relay := []activity.RelayEntry{{CallID: "a", Outcome: "ok"}, {CallID: "b", Outcome: "error"}, {CallID: "never-reached", Outcome: "offline"}, {CallID: "lost", Outcome: "ok"}, {CallID: "running", Outcome: "ok"}, {CallID: ""}}
	missingHere, missingThere := activity.Compare(log, relay, map[string]bool{"running": true})
	assert.Equal(t, []string{"lost"}, missingHere, "offline calls never reached the server; running ones aren't done")
	assert.Equal(t, []string{"local-only"}, missingThere)
}

func TestPublicEventsForClaude(t *testing.T) {
	f := files(t)
	require.NoError(t, os.MkdirAll(filepath.Dir(f.Old), 0o700))
	// Lines of the old file: one from before the mark (an event with no public words), one after.
	require.NoError(t, os.WriteFile(f.Old, []byte(`{"at":"2026-11-01T00:00:00Z","kind":"event","text":"Connected to https://relay.example as \"old\""}`+"\n"+
		`{"at":"2026-11-04T00:00:00Z","kind":"event","category":"app","text":"Latchkey 0.1.0 started","public":"Latchkey 0.1.0 started"}`+"\n"), 0o600))
	log := open(t, f)
	require.NoError(t, log.Add(activity.Entry{Kind: "call", CallID: "c1", Tool: "shell_run", Arguments: json.RawMessage(`{"command":"cat secret","public":"never shown"}`), Public: "never shown"}))
	log.Event("app", "Latchkey %s started", "0.1.1")
	log.Private("connection", false, "Connected to https://relay.example as \"box\"", "Connected as \"box\"")
	log.Private("audit", true, "Audit check: 1 call missing (call_9)", "")
	log.Problem("connection", "Disconnected: %s", "the connection dropped")

	all, err := f.Public("", 10)
	require.NoError(t, err)
	var words []string
	for _, e := range all {
		words = append(words, e.Category+": "+e.Public)
	}
	assert.Equal(t, []string{"app: Latchkey 0.1.0 started", "app: Latchkey 0.1.1 started", `connection: Connected as "box"`, "connection: Disconnected: the connection dropped"}, words,
		"oldest first, the old file too; no calls, nothing from before the mark, nothing without public words (FR-1053)")
	assert.True(t, all[3].IsError)

	last, err := f.Public("connection", 1)
	require.NoError(t, err)
	require.Len(t, last, 1)
	assert.Equal(t, "Disconnected: the connection dropped", last[0].Public, "the newest of one category")
	two, err := f.Public("app", 2)
	require.NoError(t, err)
	assert.Len(t, two, 2, "reaching back into the old file when today's isn't enough")

	mem := log.Recent("app", 10)
	require.Len(t, mem, 1, "this run's public events in memory (FR-1055)")
	assert.Equal(t, "Latchkey 0.1.1 started", mem[0].Public)
	assert.Len(t, log.Recent("", 2), 2)

	entries, _, err := f.Newest(50, nil)
	require.NoError(t, err)
	var owner bytes.Buffer
	activity.Print(&owner, entries, 50)
	assert.Contains(t, owner.String(), "Audit check: 1 call missing (call_9)", "the Owner still sees the private words")
	assert.Contains(t, owner.String(), `Connected to https://relay.example as "box"`)
	assert.Contains(t, owner.String(), `Connected to https://relay.example as "old"`)
}

func TestMemoryKeepsTheNewest1000(t *testing.T) {
	log := open(t, files(t))
	for i := range 1005 {
		log.Event("app", "line %d", i)
	}
	mem := log.Recent("", 5000)
	require.Len(t, mem, 1000)
	assert.Equal(t, "line 5", mem[0].Public)
	assert.Equal(t, "line 1004", mem[999].Public)
}

// The relay times a call as it sends it, a moment before the server logs it: asked from the
// server's first logged call exactly, the relay left that call out, and every audit check named
// it missing (purkki, 2026-11-01 to 2026-11-04). Entries from before the log began count only
// when the log has them.
func TestTheLogsFirstCallIsComparedToo(t *testing.T) {
	start := time.Date(2026, 11, 1, 17, 1, 22, 786_000_000, time.UTC)
	log := []activity.Entry{{Kind: "call", CallID: "first", At: start}, {Kind: "call", CallID: "later", At: start.Add(time.Hour)}}
	assert.True(t, activity.AuditSince(start).Before(start.Add(-time.Minute)), "asked from well before")
	relay := []activity.RelayEntry{
		{CallID: "before-the-log", At: start.Add(-5 * time.Minute), Outcome: "ok"},
		{CallID: "first", At: start.Add(-150 * time.Millisecond), Outcome: "ok"},
		{CallID: "later", At: start.Add(time.Hour), Outcome: "ok"},
	}
	missingHere, missingThere := activity.Compare(log, activity.FromLogStart(relay, start, log), nil)
	assert.Empty(t, missingThere)
	assert.Empty(t, missingHere, "a call from before the log began isn't this log's to have")
}

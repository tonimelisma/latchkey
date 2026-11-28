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

// exportFixture is an old file and three days, written out of order within a day (a long call
// is written when it ends, after a later short one).
func exportFixture(t *testing.T) activity.Files {
	t.Helper()
	f := files(t)
	require.NoError(t, os.MkdirAll(filepath.Dir(f.Old), 0o700))
	long := strings.Repeat("y", 4000) + "…"
	old := `{"at":"2026-11-01T10:00:00Z","kind":"call","call_id":"old_1","tool":"shell_run","client":"Claude","arguments":"{\"command\":\"ls\"}","result":"a\nb","duration_ms":5}` + "\n" +
		`{"at":"2026-11-01T10:00:01.25Z","kind":"call","call_id":"old_2","tool":"files_write","arguments":"{\"text\":\"` + long + `","result":"{\"ok\":true}","is_error":true,"duration_ms":7}` + "\n" +
		`{"at":"2026-11-01T10:00:02Z","kind":"event","text":"Connected to https://relay.example as \"box\""}` + "\n" +
		`not json` + "\n"
	require.NoError(t, os.WriteFile(f.Old, []byte(old), 0o600))
	log := open(t, f)
	add := func(e activity.Entry) { require.NoError(t, log.Add(e)) }
	add(activity.Entry{
		At: time.Date(2026, 11, 14, 9, 0, 1, 0, time.UTC), Kind: "call", CallID: "short", Tool: "shell_run", Client: "Claude for iOS",
		Arguments: json.RawMessage(`{"command":"echo <hi>"}`), Result: json.RawMessage(`[{"type":"text","text":"<hi>\n"}]`), DurationMS: 3,
	})
	add(activity.Entry{
		At: time.Date(2026, 11, 14, 9, 0, 0, 0, time.UTC), Kind: "call", CallID: "long", Tool: "files_read", Client: "Claude",
		Arguments: json.RawMessage(`{"path":"/tmp/a.png"}`), Result: json.RawMessage(`[{"type":"image","data":"iVBORw0KGgo=","mimeType":"image/png"}]`), DurationMS: 4000,
	})
	add(activity.Entry{At: time.Date(2026, 11, 14, 9, 0, 2, 0, time.UTC), Kind: "event", Category: "audit", IsError: true, Text: "Audit check: call_9 missing", Public: "Audit check: 1 missing"})
	add(activity.Entry{At: time.Date(2026, 11, 15, 0, 0, 0, 0, time.UTC), Kind: "call", CallID: "next_day", Tool: "shell_run", Arguments: json.RawMessage(`{}`), Result: json.RawMessage(`[]`)})
	add(activity.Entry{At: time.Date(2026, 11, 16, 23, 59, 59, 999_000_000, time.UTC), Kind: "call", CallID: "last", Tool: "shell_run", Arguments: json.RawMessage(`{}`), Result: json.RawMessage(`[]`)})
	return f
}

func export(t *testing.T, f activity.Files, from, to string) ([]string, int) {
	t.Helper()
	var out bytes.Buffer
	n, skipped, err := f.Export(&out, "homeserver", from, to)
	require.NoError(t, err)
	got := strings.Split(strings.TrimSuffix(out.String(), "\n"), "\n")
	if out.Len() == 0 {
		got = nil
	}
	assert.Len(t, got, n)
	return got, skipped
}

// The export line every side writes (FR-1059, spec 001 FR-686; trace-files.md "The export line").
func TestExportWritesTheSharedLine(t *testing.T) {
	f := exportFixture(t)
	got, skipped := export(t, f, "", "")
	assert.Equal(t, 1, skipped, "the line that isn't JSON")
	require.Len(t, got, 8)
	for _, l := range got {
		assert.Regexp(t, `^\{"v":1,"source":"linux","machine":"homeserver","time":"[^"]+","kind":"[a-z]+","tool":"[a-z_]+","arguments":.*,"result":.*,"isError":(true|false),"durationMS":\d+,"call_id":("[a-z_0-9]+"|null),"client":("[^"]+"|null)\}$`, l,
			"fields in the contract's order")
	}
	assert.Contains(t, got[4], `"arguments":{"command":"echo <hi>"}`, "nothing escaped")
	assert.JSONEq(t,
		`{"v":1,"source":"linux","machine":"homeserver","time":"2026-11-01T10:00:00.000Z","kind":"action","tool":"shell_run","arguments":{"command":"ls"},"result":"a\nb","isError":false,"durationMS":5,"call_id":"old_1","client":"Claude"}`,
		got[0], "fields in the contract's order; version 0's arguments that are JSON stay JSON, its result is text")
	var cut map[string]any
	require.NoError(t, json.Unmarshal([]byte(got[1]), &cut))
	assert.Equal(t, `{"text":"`+strings.Repeat("y", 4000)+"…", cut["arguments"], "cut arguments aren't JSON: a string")
	assert.Equal(t, `{"ok":true}`, cut["result"], "version 0's result is always text")
	assert.Equal(t, true, cut["isError"])
	assert.Equal(t, "2026-11-01T10:00:01.250Z", cut["time"])
	assert.JSONEq(t,
		`{"v":1,"source":"linux","machine":"homeserver","time":"2026-11-01T10:00:02.000Z","kind":"event","tool":"event","arguments":"","result":"Connected to https://relay.example as \"box\"","isError":false,"durationMS":0,"call_id":null,"client":null}`,
		got[2], "an old event without a category: its kind")
	assert.JSONEq(t,
		`{"v":1,"source":"linux","machine":"homeserver","time":"2026-11-14T09:00:00.000Z","kind":"action","tool":"files_read","arguments":{"path":"/tmp/a.png"},"result":[{"type":"image","data":"iVBORw0KGgo=","mimeType":"image/png"}],"isError":false,"durationMS":4000,"call_id":"long","client":"Claude"}`,
		got[3], "oldest first by when the call began, though written last; the image whole")
	assert.JSONEq(t,
		`{"v":1,"source":"linux","machine":"homeserver","time":"2026-11-14T09:00:01.000Z","kind":"action","tool":"shell_run","arguments":{"command":"echo <hi>"},"result":[{"type":"text","text":"<hi>\n"}],"isError":false,"durationMS":3,"call_id":"short","client":"Claude for iOS"}`,
		got[4], "nothing escaped")
	assert.JSONEq(t,
		`{"v":1,"source":"linux","machine":"homeserver","time":"2026-11-14T09:00:02.000Z","kind":"event","tool":"audit","arguments":"","result":"Audit check: call_9 missing","isError":true,"durationMS":0,"call_id":null,"client":null}`,
		got[5], "an event: its category and the Owner's words")
	assert.Contains(t, got[7], `"call_id":"last"`)
	assert.Contains(t, got[6], `"client":null`)
}

// Both days are included, in UTC; the old file's lines are filtered by their day too.
func TestExportFromAndTo(t *testing.T) {
	f := exportFixture(t)
	ids := func(from, to string) []string {
		got, _ := export(t, f, from, to)
		var out []string
		for _, l := range got {
			var m struct {
				CallID *string `json:"call_id"`
				Kind   string  `json:"kind"`
			}
			require.NoError(t, json.Unmarshal([]byte(l), &m))
			if m.CallID == nil {
				out = append(out, m.Kind)
			} else {
				out = append(out, *m.CallID)
			}
		}
		return out
	}
	assert.Equal(t, []string{"long", "short", "event", "next_day"}, ids("2026-11-14", "2026-11-15"))
	assert.Equal(t, []string{"next_day", "last"}, ids("2026-11-15", ""))
	assert.Equal(t, []string{"old_1", "old_2", "event"}, ids("", "2026-11-01"))
	assert.Equal(t, []string{"last"}, ids("2026-11-16", "2026-11-16"))
	assert.Empty(t, ids("2026-11-02", "2026-11-13"))

	var out bytes.Buffer
	_, _, err := f.Export(&out, "x", "2026-11-5", "")
	require.Error(t, err, "a day is YYYY-MM-DD")
	_, _, err = f.Export(&out, "x", "2026-11-16", "2026-11-15")
	require.Error(t, err, "from after to")
}

// The requirements this file's tests cite (docs/requirements/; script/process-check).
// Validates: FR-686, FR-1059

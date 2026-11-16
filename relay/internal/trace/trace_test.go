package trace

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var (
	keyFile = []byte("0123456789abcdef0123456789abcdef")
	t0      = time.Date(2026, 11, 15, 23, 59, 59, 123_000_000, time.UTC)
)

type fakeDisk struct {
	mu    sync.Mutex
	free  uint64
	calls int
}

func (d *fakeDisk) space(string) (uint64, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.calls++
	return d.free, nil
}

func (d *fakeDisk) set(free uint64) {
	d.mu.Lock()
	d.free = free
	d.mu.Unlock()
}

type clock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *clock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *clock) add(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

func open(t *testing.T, tweak func(*Options)) (*Store, string) {
	t.Helper()
	key, err := hkdf.Key(sha256.New, keyFile, nil, KeyInfo, 32)
	require.NoError(t, err)
	dir := filepath.Join(t.TempDir(), "traces")
	o := Options{Dir: dir, Key: key, FreeSpace: (&fakeDisk{free: 100 << 30}).space}
	if tweak != nil {
		tweak(&o)
	}
	s, err := New(o)
	require.NoError(t, err)
	return s, dir
}

func call(tool string, args string) Line {
	return Line{
		Machine: "Toni's Mac", Kind: KindAction, Tool: tool, Arguments: JSONOrString([]byte(args)),
		Result: json.RawMessage(`[{"type":"text","text":"ok <&>  "}]`), DurationMS: 12,
		CallID: "call_1", Client: "claude-ai", Outcome: "ok",
	}
}

func all(t *testing.T, s *Store, account, from, to string) ([]Line, int) {
	t.Helper()
	var got []Line
	skipped, err := s.Each(account, from, to, func(l Line) error {
		got = append(got, l)
		return nil
	})
	require.NoError(t, err)
	return got, skipped
}

// The stored line is {"v":1,"sealed":…}: AES-256-GCM under HKDF-SHA256(key file, "latchkey relay
// traces v1"), the account and day as authenticated data, and inside it the export line with
// source "relay" and no account (contracts/trace-files.md).
func TestLineFormatAndEncryption(t *testing.T) {
	s, dir := open(t, nil)
	s.Append("usr_a", t0, call("shell_run", `{"command":"ls <x>","machine":"Toni's Mac"}`))

	path := filepath.Join(dir, "usr_a", "2026-11-15.trace")
	data, err := os.ReadFile(path)
	require.NoError(t, err)
	require.True(t, bytes.HasSuffix(data, []byte("\n")))
	var outer map[string]any
	require.NoError(t, json.Unmarshal(data, &outer))
	assert.Equal(t, map[string]any{"v": float64(1), "sealed": outer["sealed"]}, outer)
	assert.NotContains(t, string(data), "shell_run", "nothing in the clear")

	sealed, err := base64.StdEncoding.DecodeString(outer["sealed"].(string))
	require.NoError(t, err)
	key, err := hkdf.Key(sha256.New, keyFile, nil, "latchkey relay traces v1", 32)
	require.NoError(t, err)
	block, err := aes.NewCipher(key)
	require.NoError(t, err)
	gcm, err := cipher.NewGCM(block)
	require.NoError(t, err)
	plain, err := gcm.Open(nil, sealed[:12], sealed[12:], []byte("usr_a/2026-11-15"))
	require.NoError(t, err, "the account and day are the authenticated data")
	assert.JSONEq(t, `{"v":1,"source":"relay","machine":"Toni's Mac","time":"2026-11-15T23:59:59.123Z",
		"kind":"action","tool":"shell_run","arguments":{"command":"ls <x>","machine":"Toni's Mac"},
		"result":[{"type":"text","text":"ok <&>  "}],"isError":false,"durationMS":12,
		"call_id":"call_1","client":"claude-ai","outcome":"ok"}`, string(plain))
	assert.Contains(t, string(plain), `"ls <x>"`, "no HTML escaping: the arguments as Claude sent them")
	assert.NotContains(t, string(plain), `"account"`)
	assert.True(t, strings.HasPrefix(string(plain), `{"v":1,"source":"relay","machine":`), "fields in the contract's order")

	got, skipped := all(t, s, "usr_a", "", "")
	assert.Zero(t, skipped)
	require.Len(t, got, 1)
	assert.Equal(t, "shell_run", got[0].Tool)
}

// Folders 0700, files 0600 (contracts/trace-files.md).
func TestPermissions(t *testing.T) {
	s, dir := open(t, nil)
	s.Append("usr_a", t0, call("x", `{}`))
	for path, want := range map[string]os.FileMode{
		dir: 0o700, filepath.Join(dir, "usr_a"): 0o700, filepath.Join(dir, "usr_a", "2026-11-15.trace"): 0o600,
	} {
		info, err := os.Stat(path)
		require.NoError(t, err)
		assert.Equal(t, want, info.Mode().Perm(), path)
	}
}

// A line can't be moved to another account's folder or to another day.
func TestAuthenticatedDataBindsAccountAndDay(t *testing.T) {
	s, dir := open(t, nil)
	s.Append("usr_a", t0, call("x", `{}`))
	s.Append("usr_b", t0.Add(time.Hour), call("y", `{}`)) // 2026-11-16
	a, err := os.ReadFile(filepath.Join(dir, "usr_a", "2026-11-15.trace"))
	require.NoError(t, err)

	// Into another account's day, and into the same account's other day.
	require.NoError(t, os.WriteFile(filepath.Join(dir, "usr_b", "2026-11-15.trace"), a, 0o600))
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "usr_a"), 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "usr_a", "2026-11-16.trace"), a, 0o600))

	got, skipped := all(t, s, "usr_b", "", "")
	assert.Equal(t, 1, skipped, "the moved line doesn't open")
	require.Len(t, got, 1)
	assert.Equal(t, "y", got[0].Tool)
	got, skipped = all(t, s, "usr_a", "", "")
	assert.Equal(t, 1, skipped)
	require.Len(t, got, 1)
	assert.Equal(t, "x", got[0].Tool)
}

// Only ever appended to; every line fsynced before it counts; a line is filed by the UTC day of
// its start.
func TestAppendOnlyDailyFilesSynced(t *testing.T) {
	var synced int
	s, dir := open(t, nil)
	s.sync = func(f *os.File) error {
		synced++
		return f.Sync()
	}
	local := time.FixedZone("PST", -8*3600)
	s.Append("usr_a", t0, call("one", `{}`))
	path := filepath.Join(dir, "usr_a", "2026-11-15.trace")
	first, err := os.ReadFile(path)
	require.NoError(t, err)
	s.Append("usr_a", t0.Add(-time.Hour).In(local), call("two", `{}`)) // 2026-11-15 in UTC, the 15th there too
	s.Append("usr_a", t0.Add(time.Second).In(local), call("three", `{}`))
	assert.Equal(t, 3, synced, "one fsync per line")

	after, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.True(t, bytes.HasPrefix(after, first), "earlier lines stay as written")
	assert.Equal(t, 2, bytes.Count(after, []byte("\n")))
	_, err = os.Stat(filepath.Join(dir, "usr_a", "2026-11-16.trace"))
	require.NoError(t, err, "the UTC day of the start names the file, whatever the time zone")

	// A failing fsync is logged, never a failure of the call that was traced.
	s.sync = func(*os.File) error { return errors.New("disk on fire") }
	s.Append("usr_a", t0, call("four", `{}`))
}

// Lines that can't be read (cut short, another version, not JSON, a wrong key) are skipped and
// counted; the reader goes on and never changes the file. A write after a cut-off line starts on
// a line of its own.
func TestReadersSkipAndCountBadLines(t *testing.T) {
	s, dir := open(t, nil)
	s.Append("usr_a", t0.Add(-2*time.Hour), call("good1", `{}`))
	path := filepath.Join(dir, "usr_a", "2026-11-15.trace")
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0o600)
	require.NoError(t, err)
	_, err = f.WriteString("not json\n" + `{"v":2,"sealed":"AAAA"}` + "\n" + `{"v":1,"sealed":"AAAA"}` + "\n" + `{"v":1,"seal`)
	require.NoError(t, err)
	require.NoError(t, f.Close())
	before, err := os.ReadFile(path)
	require.NoError(t, err)

	s.Append("usr_a", t0.Add(-time.Hour), call("good2", `{}`))
	got, skipped := all(t, s, "usr_a", "", "")
	assert.Equal(t, 4, skipped)
	require.Len(t, got, 2)
	assert.Equal(t, "good1", got[0].Tool)
	assert.Equal(t, "good2", got[1].Tool, "the line after a cut-off one is whole")

	after, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.True(t, bytes.HasPrefix(after, before), "reading and writing never change what is there")

	// A store with another key reads nothing and says so.
	other, err := New(Options{Dir: dir, Key: bytes.Repeat([]byte{9}, 32), FreeSpace: (&fakeDisk{free: 100 << 30}).space})
	require.NoError(t, err)
	got, skipped = all(t, other, "usr_a", "", "")
	assert.Empty(t, got)
	assert.Equal(t, 6, skipped)
}

// A line cut short by a crash costs only that line: the next write ends it with "\n" first, so
// the new entry reads; the cut-off line is skipped and counted; earlier bytes stay as they were.
func TestCutOffLineIsEndedBeforeTheNextWrite(t *testing.T) {
	s, dir := open(t, nil)
	s.Append("usr_a", t0.Add(-time.Hour), call("before", `{}`))
	path := filepath.Join(dir, "usr_a", "2026-11-15.trace")
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0o600)
	require.NoError(t, err)
	_, err = f.WriteString(`{"v":1,"sealed":"AbCd`) // the crash: no end of line
	require.NoError(t, err)
	require.NoError(t, f.Close())
	cut, err := os.ReadFile(path)
	require.NoError(t, err)

	s.Append("usr_a", t0, call("after", `{}`))
	after, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.True(t, bytes.HasPrefix(after, cut), "earlier bytes unchanged")
	assert.Equal(t, byte('\n'), after[len(cut)], "the cut-off line is ended first")
	got, skipped := all(t, s, "usr_a", "", "")
	assert.Equal(t, 1, skipped, "the cut-off line is skipped and counted")
	require.Len(t, got, 2)
	assert.Equal(t, "before", got[0].Tool)
	assert.Equal(t, "after", got[1].Tool, "the new entry reads")
}

// Oldest first across days and within a day (a long call that began first is written last);
// from and to are days, both included.
func TestEachOldestFirstWithDays(t *testing.T) {
	s, _ := open(t, nil)
	day := func(d int, h int) time.Time { return time.Date(2026, 11, d, h, 0, 0, 0, time.UTC) }
	s.Append("usr_a", day(14, 9), call("d14", `{}`))
	s.Append("usr_a", day(15, 10), call("d15-late", `{}`))
	s.Append("usr_a", day(15, 8), call("d15-early", `{}`)) // began earlier, ended later
	s.Append("usr_a", day(16, 1), call("d16", `{}`))
	tools := func(ls []Line) []string {
		var out []string
		for _, l := range ls {
			out = append(out, l.Tool)
		}
		return out
	}
	got, _ := all(t, s, "usr_a", "", "")
	assert.Equal(t, []string{"d14", "d15-early", "d15-late", "d16"}, tools(got))
	got, _ = all(t, s, "usr_a", "2026-11-15", "")
	assert.Equal(t, []string{"d15-early", "d15-late", "d16"}, tools(got))
	got, _ = all(t, s, "usr_a", "", "2026-11-15")
	assert.Equal(t, []string{"d14", "d15-early", "d15-late"}, tools(got))
	got, _ = all(t, s, "usr_a", "2026-11-15", "2026-11-15")
	assert.Equal(t, []string{"d15-early", "d15-late"}, tools(got))
	got, skipped := all(t, s, "usr_nobody", "", "")
	assert.Empty(t, got)
	assert.Zero(t, skipped)
}

// The export adds the account's address to each line, one JSON object per line.
func TestExport(t *testing.T) {
	s, _ := open(t, nil)
	s.Append("usr_a", t0, call("shell_run", `{"command":"echo <hi>"}`))
	s.Append("usr_a", t0.Add(time.Millisecond), Event("mac_connected", "app 0.9.0", ""))
	var out bytes.Buffer
	skipped, err := s.Export("usr_a", "owner@example.com", "", "", &out)
	require.NoError(t, err)
	assert.Zero(t, skipped)
	lines := strings.Split(strings.TrimSuffix(out.String(), "\n"), "\n")
	require.Len(t, lines, 2)
	assert.JSONEq(t, `{"v":1,"source":"relay","machine":"Toni's Mac","time":"2026-11-15T23:59:59.123Z",
		"kind":"action","tool":"shell_run","arguments":{"command":"echo <hi>"},
		"result":[{"type":"text","text":"ok <&>  "}],"isError":false,"durationMS":12,
		"call_id":"call_1","client":"claude-ai","outcome":"ok","account":"owner@example.com"}`, lines[0])
	assert.Contains(t, lines[0], `"echo <hi>"`)
	assert.JSONEq(t, `{"v":1,"source":"relay","machine":null,"time":"2026-11-15T23:59:59.124Z",
		"kind":"event","tool":"mac_connected","arguments":"","result":"app 0.9.0","isError":false,
		"durationMS":0,"call_id":null,"client":null,"account":"owner@example.com"}`, lines[1])
}

func TestJSONOrString(t *testing.T) {
	assert.JSONEq(t, `{"a":1}`, string(JSONOrString([]byte(`{"a": 1}`))))
	assert.Equal(t, `"not json"`, string(JSONOrString([]byte("not json"))))
	assert.Equal(t, `""`, string(JSONOrString(nil)), "no arguments sent")
}

// FR-684: below 2 GiB free nothing is written and the pause is reported once; with 2 GiB or more
// again writing resumes and that is reported once. Free space is checked at most every 10 s.
func TestLowDiskPausesAndResumes(t *testing.T) {
	disk := &fakeDisk{free: 1 << 30}
	clk := &clock{now: t0}
	type change struct {
		paused bool
		free   uint64
	}
	var changes []change
	s, dir := open(t, func(o *Options) {
		o.FreeSpace, o.Now = disk.space, clk.Now
	})
	s.OnPauseChange(func(paused bool, free uint64) { changes = append(changes, change{paused, free}) })
	assert.Equal(t, uint64(2<<30), s.o.MinFree, "2 GiB by default")
	assert.Equal(t, 10*time.Second, s.o.CheckEvery)

	path := filepath.Join(dir, "usr_a", "2026-11-15.trace")
	s.Append("usr_a", t0, call("a", `{}`))
	s.Append("usr_a", t0, call("b", `{}`))
	_, err := os.Stat(path)
	require.ErrorIs(t, err, os.ErrNotExist, "nothing written while the disk is low")
	assert.Equal(t, []change{{true, 1 << 30}}, changes, "the pause is reported once")
	assert.Equal(t, 1, disk.calls, "checked at most every 10 seconds")

	disk.set(3 << 30)
	s.Append("usr_a", t0, call("c", `{}`))
	_, err = os.Stat(path)
	require.ErrorIs(t, err, os.ErrNotExist, "the answer is kept for 10 seconds")
	clk.add(10 * time.Second)
	s.Append("usr_a", t0, call("d", `{}`))
	s.Append("usr_a", t0, call("e", `{}`))
	assert.Equal(t, []change{{true, 1 << 30}, {false, 3 << 30}}, changes)
	got, _ := all(t, s, "usr_a", "", "")
	require.Len(t, got, 2)
	assert.Equal(t, "d", got[0].Tool)

	// Exactly 2 GiB free is enough; the files are never deleted to make room.
	disk.set(2 << 30)
	clk.add(10 * time.Second)
	s.Append("usr_a", t0, call("f", `{}`))
	got, _ = all(t, s, "usr_a", "", "")
	assert.Len(t, got, 3)
	disk.set(0)
	clk.add(10 * time.Second)
	s.Append("usr_a", t0, call("g", `{}`))
	got, _ = all(t, s, "usr_a", "", "")
	assert.Len(t, got, 3, "low disk deletes nothing")
	assert.Len(t, changes, 3)
}

// FR-687: Delete removes the account's folder and nothing else; a line for an account that no
// longer exists doesn't make its folder again.
func TestDeleteAndNoFolderForAGoneAccount(t *testing.T) {
	exists := map[string]bool{"usr_a": true, "usr_b": true}
	var mu sync.Mutex
	s, dir := open(t, func(o *Options) {
		o.AccountExists = func(id string) bool {
			mu.Lock()
			defer mu.Unlock()
			return exists[id]
		}
	})
	s.Append("usr_a", t0, call("a", `{}`))
	s.Append("usr_b", t0, call("b", `{}`))
	require.NoError(t, s.Delete("usr_a"))
	_, err := os.Stat(filepath.Join(dir, "usr_a"))
	require.ErrorIs(t, err, os.ErrNotExist)
	_, err = os.Stat(filepath.Join(dir, "usr_b", "2026-11-15.trace"))
	require.NoError(t, err)
	require.NoError(t, s.Delete("usr_a"), "deleting twice is fine")

	mu.Lock()
	exists["usr_a"] = false
	mu.Unlock()
	s.Append("usr_a", t0, call("late", `{}`)) // a call that ended after the deletion
	_, err = os.Stat(filepath.Join(dir, "usr_a"))
	require.ErrorIs(t, err, os.ErrNotExist)
}

// An account ID that isn't one the relay makes never becomes a path.
func TestBadAccountIDs(t *testing.T) {
	s, dir := open(t, nil)
	for _, id := range []string{"", "..", "../x", "a/b", `a\b`, ".hidden", strings.Repeat("a", 200)} {
		s.Append(id, t0, call("x", `{}`))
		require.Error(t, s.Delete(id), id)
		_, err := s.Each(id, "", "", func(Line) error { return nil })
		require.Error(t, err, id)
	}
	entries, err := os.ReadDir(dir)
	require.NoError(t, err)
	assert.Empty(t, entries)
	_, err = os.Stat(filepath.Join(filepath.Dir(dir), "x"))
	require.ErrorIs(t, err, os.ErrNotExist)
}

func TestBadDays(t *testing.T) {
	s, _ := open(t, nil)
	_, err := s.Each("usr_a", "2026-13-01", "", func(Line) error { return nil })
	require.Error(t, err)
	_, err = s.Each("usr_a", "", "yesterday", func(Line) error { return nil })
	require.Error(t, err)
}

// A nil store traces nothing and doesn't fail.
func TestNilStore(t *testing.T) {
	var s *Store
	s.Append("usr_a", t0, call("x", `{}`))
	require.NoError(t, s.Delete("usr_a"))
	s.OnPauseChange(func(bool, uint64) {})
}

// Many calls at once each leave one whole line.
func TestConcurrentAppends(t *testing.T) {
	s, _ := open(t, nil)
	var wg sync.WaitGroup
	big := strings.Repeat("x", 256<<10)
	for range 20 {
		wg.Go(func() {
			l := call("x", `{}`)
			l.Result = String(big)
			s.Append("usr_a", t0, l)
		})
	}
	wg.Wait()
	got, skipped := all(t, s, "usr_a", "", "")
	assert.Zero(t, skipped)
	assert.Len(t, got, 20)
}

// Writing a call with a large screenshot stays well within what a call already takes.
func BenchmarkAppendScreenshot(b *testing.B) {
	key := bytes.Repeat([]byte{1}, 32)
	s, err := New(Options{Dir: filepath.Join(b.TempDir(), "traces"), Key: key, FreeSpace: (&fakeDisk{free: 100 << 30}).space})
	require.NoError(b, err)
	l := call("computer_look", `{}`)
	l.Result = json.RawMessage(`[{"type":"image","mimeType":"image/png","data":"` + strings.Repeat("A", 4<<20) + `"}]`)
	b.ResetTimer()
	for b.Loop() {
		s.Append("usr_a", t0, l)
	}
}

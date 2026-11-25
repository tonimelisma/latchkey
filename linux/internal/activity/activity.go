// Package activity is the server's activity log (spec 010 FR-1050, FR-1051, FR-1057 to FR-1059,
// plan D11; spec 001 contracts/trace-files.md "Linux server"): one JSON line per tool call and
// per event, in a file of one day each (UTC) that only the Owner's account can read, with every
// call's arguments and result in full. There are no notifications on a server; the log is read
// with `latchkey activity`, exported with `latchkey activity export`, and compared with the
// relay's audit after each connection.
//
// The single file of versions before 2026-11-15 (arguments and results cut short) is never
// written again and still read, as version 0. Nothing here ever changes a file once written:
// lines are only appended, and a line that can't be read is skipped and counted.
package activity

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
)

// Version is the format of the lines this version writes.
const Version = 1

const (
	dayLayout  = "2006-01-02"
	timeLayout = "2006-01-02T15:04:05.000Z07:00" // RFC 3339 with milliseconds
	suffix     = ".jsonl"
)

// Files is where the log is: the folder of daily files and the single file of earlier versions.
type Files struct {
	Dir string // one file a day, YYYY-MM-DD.jsonl
	Old string // activity.jsonl, version 0; only read
}

// Entry is one line.
type Entry struct {
	V      int       `json:"-"` // the line's format: 0 (the old file) or 1
	At     time.Time `json:"at"`
	Kind   string    `json:"kind"`              // "call" or "event"
	CallID string    `json:"call_id,omitempty"` // the relay's call id
	Tool   string    `json:"tool,omitempty"`
	Client string    `json:"client,omitempty"` // the Claude app, as the relay names it
	// Arguments are the call's arguments as JSON exactly as they came; in a version 0 line a
	// JSON string, the arguments' text cut to 4,000 characters.
	Arguments json.RawMessage `json:"arguments,omitempty"`
	// Result is the MCP content array as sent to the relay, as JSON; in a version 0 line a JSON
	// string, the result's text cut to 2,000 characters.
	Result     json.RawMessage `json:"result,omitempty"`
	IsError    bool            `json:"is_error,omitempty"`
	DurationMS int64           `json:"duration_ms,omitempty"`
	Text       string          `json:"text,omitempty"` // an event's words, for the Owner
	// Category is an event's kind (latchkey_log's categories: app, connection, pairing,
	// settings, pause, update, audit).
	Category string `json:"category,omitempty"`
	// Public is the event's words Claude may see through latchkey_log (FR-1053): Text itself, or
	// Text without its private detail; empty: none (so also every event recorded before the
	// mark, 2026-11-03).
	Public string `json:"public,omitempty"`
}

// shown reports whether Claude may see the entry: an event with public words, of the category
// ("" any).
func (e Entry) shown(category string) bool {
	return e.Kind == "event" && e.Public != "" && (category == "" || e.Category == category)
}

// ArgumentsText is the arguments as text for people: version 0's cut text, or the JSON.
func (e Entry) ArgumentsText() string { return text(e.Arguments) }

// text is a JSON string's value, or any other JSON as it is.
func text(raw json.RawMessage) string {
	var s string
	if len(raw) > 0 && raw[0] == '"' && json.Unmarshal(raw, &s) == nil {
		return s
	}
	return string(raw)
}

// line is how version 1 stores an entry (trace-files.md "Linux server"), fields in this order.
type line struct {
	V          int             `json:"v"`
	At         string          `json:"at"`
	Kind       string          `json:"kind"`
	CallID     string          `json:"call_id,omitempty"`
	Tool       string          `json:"tool,omitempty"`
	Client     string          `json:"client,omitempty"`
	Arguments  json.RawMessage `json:"arguments,omitempty"`
	Result     json.RawMessage `json:"result,omitempty"`
	IsError    bool            `json:"is_error,omitempty"`
	DurationMS int64           `json:"duration_ms,omitempty"`
	Text       string          `json:"text,omitempty"`
	Category   string          `json:"category,omitempty"`
	Public     string          `json:"public,omitempty"`
}

// stored reads a line of any version.
type stored struct {
	V *int `json:"v"`
	Entry
}

// MaxRecent is how many of this run's public events the log keeps in memory (FR-1055).
const MaxRecent = 1000

// Log appends entries.
type Log struct {
	mu     sync.Mutex
	files  Files
	recent []Entry // this run's public events, oldest first
}

// Open makes the daily files' folder, readable only by the Owner. The old file is left alone.
func Open(f Files) (*Log, error) {
	if err := os.MkdirAll(f.Dir, 0o700); err != nil {
		return nil, err
	}
	if err := os.Chmod(f.Dir, 0o700); err != nil { //nolint:gosec // a folder: 0700 is the Owner's only
		return nil, err
	}
	return &Log{files: f}, nil
}

// Files is where the log is.
func (l *Log) Files() Files { return l.files }

// Add writes an entry whole to its day's file and synchronizes the file. An error only means
// the entry isn't on disk; the caller carries on (a call never fails for its log).
func (l *Log) Add(e Entry) error {
	if e.At.IsZero() {
		e.At = time.Now()
	}
	e.At = e.At.UTC().Truncate(time.Millisecond)
	e.V = Version
	data, err := encode(e)
	if err != nil {
		return err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if e.shown("") {
		if len(l.recent) == MaxRecent {
			l.recent = append(l.recent[:0], l.recent[1:]...)
		}
		l.recent = append(l.recent, e)
	}
	return l.files.append(e.At.Format(dayLayout), data)
}

// encode is the entry's version 1 line, with its line break.
func encode(e Entry) ([]byte, error) {
	l := line{
		V: Version, At: e.At.Format(timeLayout), Kind: e.Kind, CallID: e.CallID, Tool: e.Tool, Client: e.Client,
		Arguments: asJSON(e.Arguments, e.Kind == "call"), Result: asJSON(e.Result, e.Kind == "call"),
		IsError: e.IsError, DurationMS: e.DurationMS, Text: e.Text, Category: e.Category, Public: e.Public,
	}
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(l); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

// asJSON keeps JSON as it is, turns anything else into a JSON string, and gives a call that had
// none null.
func asJSON(raw json.RawMessage, call bool) json.RawMessage {
	switch {
	case len(raw) == 0 && call:
		return json.RawMessage("null")
	case len(raw) == 0 || json.Valid(raw):
		return raw
	}
	return quote(string(raw))
}

// quote is s as a JSON string, with <, >, and & as they are.
func quote(s string) json.RawMessage {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(s)
	return bytes.TrimSuffix(b.Bytes(), []byte("\n"))
}

func (f Files) append(day string, data []byte) error {
	if err := os.MkdirAll(f.Dir, 0o700); err != nil {
		return err
	}
	file, err := os.OpenFile(filepath.Join(f.Dir, day+suffix), os.O_CREATE|os.O_APPEND|os.O_RDWR, 0o600) //nolint:gosec // the program's own log, in its data folder
	if err != nil {
		return err
	}
	info, err := file.Stat()
	if err == nil && info.Mode().Perm() != 0o600 {
		err = file.Chmod(0o600)
	}
	if err == nil && info.Size() > 0 {
		// A write cut short (a crash, a full disk) left no line break: start on a line of our own,
		// so this entry isn't joined to the broken one.
		last := make([]byte, 1)
		if _, err = file.ReadAt(last, info.Size()-1); err == nil && last[0] != '\n' {
			data = append([]byte{'\n'}, data...)
		}
	}
	if err == nil {
		_, err = file.Write(data)
	}
	if err == nil {
		err = file.Sync()
	}
	return errors.Join(err, file.Close())
}

// Event records something that happened in words with nothing private in them (FR-1053): the
// Owner and Claude see the same.
func (l *Log) Event(category, format string, a ...any) {
	text := fmt.Sprintf(format, a...)
	_ = l.Add(Entry{Kind: "event", Category: category, Text: text, Public: text})
}

// Problem records something that went wrong, in words with nothing private in them.
func (l *Log) Problem(category, format string, a ...any) {
	text := fmt.Sprintf(format, a...)
	_ = l.Add(Entry{Kind: "event", Category: category, IsError: true, Text: text, Public: text})
}

// Private records an event whose words for the Owner hold a private detail (the relay's
// address, a path, a call ID); public is the version without it that Claude may see, "" none.
func (l *Log) Private(category string, isError bool, text, public string) {
	_ = l.Add(Entry{Kind: "event", Category: category, IsError: isError, Text: text, Public: public})
}

// Recent is this run's newest n public events of the category ("" any), oldest first.
func (l *Log) Recent(category string, n int) []Entry {
	l.mu.Lock()
	defer l.mu.Unlock()
	var out []Entry
	for i := len(l.recent) - 1; i >= 0 && len(out) < n; i-- {
		if l.recent[i].shown(category) {
			out = append(out, l.recent[i])
		}
	}
	slices.Reverse(out)
	return out
}

// decode reads one line of any version this program knows; false for one it can't read.
func decode(b []byte) (Entry, bool) {
	var s stored
	if json.Unmarshal(b, &s) != nil {
		return Entry{}, false
	}
	switch {
	case s.V == nil:
		s.Entry.V = 0
	case *s.V == Version:
		s.Entry.V = Version
	default:
		return Entry{}, false // a version this program doesn't know
	}
	return s.Entry, true
}

// head is the little of a line the comparison and the export's ordering need; decoding only
// these leaves a call's large result unread into memory.
type head struct {
	V      *int      `json:"v"`
	At     time.Time `json:"at"`
	Kind   string    `json:"kind"`
	CallID string    `json:"call_id"`
}

func decodeHead(b []byte) (head, bool) {
	var h head
	if json.Unmarshal(b, &h) != nil || (h.V != nil && *h.V != Version) {
		return head{}, false
	}
	return h, true
}

// scan calls fn with each line of the file that isn't blank, without its line break, and where
// it begins.
func scan(path string, fn func(b []byte, off int64)) error {
	file, err := os.Open(path) //nolint:gosec // the program's own log, in its data folder
	if err != nil {
		return err
	}
	defer func() { _ = file.Close() }()
	r := bufio.NewReaderSize(file, 64<<10)
	var off int64
	for {
		b, err := r.ReadBytes('\n')
		start := off
		off += int64(len(b))
		if t := bytes.TrimSpace(b); len(t) > 0 {
			fn(bytes.TrimRight(b, "\r\n"), start)
		}
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

// days lists the daily files' days from from to to (both included, "" open), oldest first, and
// whether the old file is there. Neither there at all is fs.ErrNotExist.
func (f Files) days(from, to string) (days []string, old bool, err error) {
	list, err := os.ReadDir(f.Dir)
	dirThere := err == nil
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, false, err
	}
	for _, d := range list {
		day, ok := strings.CutSuffix(d.Name(), suffix)
		if !ok || !isDay(day) || (from != "" && day < from) || (to != "" && day > to) {
			continue
		}
		days = append(days, day)
	}
	sort.Strings(days)
	if _, err := os.Stat(f.Old); err == nil {
		old = true
	} else if !errors.Is(err, fs.ErrNotExist) {
		return nil, false, err
	}
	if !dirThere && !old {
		return nil, false, fs.ErrNotExist
	}
	return days, old, nil
}

func isDay(s string) bool {
	_, err := time.Parse(dayLayout, s)
	return err == nil && len(s) == len(dayLayout)
}

func (f Files) dayPath(day string) string { return filepath.Join(f.Dir, day+suffix) }

// Newest returns the log's newest n entries that keep accepts (nil: all), oldest first, and how
// many lines couldn't be read. It reads the newest day first and stops once it has n; keep may
// change the entry it keeps (dropping a result it doesn't need, say).
func (f Files) Newest(n int, keep func(*Entry) bool) ([]Entry, int, error) {
	return f.newest(n, nil, keep)
}

// newest is Newest reading only lines that contain hint (nil: all).
func (f Files) newest(n int, hint []byte, keep func(*Entry) bool) ([]Entry, int, error) {
	days, old, err := f.days("", "")
	if err != nil || n <= 0 {
		return nil, 0, err
	}
	var paths []string
	for i := len(days) - 1; i >= 0; i-- {
		paths = append(paths, f.dayPath(days[i]))
	}
	if old {
		paths = append(paths, f.Old)
	}
	var found []Entry
	skipped := 0
	for _, path := range paths {
		ring := make([]Entry, 0, min(n, 64))
		oldest := 0 // ring's oldest once it is full
		err := scan(path, func(b []byte, _ int64) {
			if hint != nil && !bytes.Contains(b, hint) {
				return
			}
			e, ok := decode(b)
			if !ok {
				skipped++
				return
			}
			if keep != nil && !keep(&e) {
				return
			}
			if len(ring) < n {
				ring = append(ring, e)
			} else {
				ring[oldest] = e
				oldest = (oldest + 1) % n
			}
		})
		if err != nil {
			return nil, skipped, err
		}
		found = append(append(ring[oldest:], ring[:oldest]...), found...)
		if len(found) >= n {
			break
		}
	}
	sort.SliceStable(found, func(i, j int) bool { return found[i].At.Before(found[j].At) })
	if len(found) > n {
		found = found[len(found)-n:]
	}
	return found, skipped, nil
}

// Public returns the log's newest n events Claude may see, of the category ("" any), oldest
// first (FR-1053): never a call, never an event without public words.
func (f Files) Public(category string, n int) ([]Entry, error) {
	found, _, err := f.newest(n, []byte(`"public":`), func(e *Entry) bool { return e.shown(category) })
	return found, err
}

// Calls returns the calls from from to to (zero: open), oldest first, with only their time and
// call id (what the comparison with the relay needs), and how many lines couldn't be read. It
// opens only the days in the range, and the old file.
func (f Files) Calls(from, to time.Time) ([]Entry, int, error) {
	fromDay, toDay := "", ""
	if !from.IsZero() {
		fromDay = from.UTC().Format(dayLayout)
	}
	if !to.IsZero() {
		toDay = to.UTC().Format(dayLayout)
	}
	days, old, err := f.days(fromDay, toDay)
	if err != nil {
		return nil, 0, err
	}
	var paths []string
	if old {
		paths = append(paths, f.Old)
	}
	for _, d := range days {
		paths = append(paths, f.dayPath(d))
	}
	var out []Entry
	skipped := 0
	for _, path := range paths {
		err := scan(path, func(b []byte, _ int64) {
			h, ok := decodeHead(b)
			if !ok {
				skipped++
				return
			}
			if h.Kind != "call" || (!from.IsZero() && h.At.Before(from)) || (!to.IsZero() && h.At.After(to)) {
				return
			}
			v := 0
			if h.V != nil {
				v = *h.V
			}
			out = append(out, Entry{V: v, At: h.At, Kind: h.Kind, CallID: h.CallID})
		})
		if err != nil {
			return nil, skipped, err
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].At.Before(out[j].At) })
	return out, skipped, nil
}

// maxShown is how much of a call's arguments `latchkey activity` prints; the log keeps them all.
const maxShown = 4000

// Print writes the last n entries for the Owner to read.
func Print(w io.Writer, entries []Entry, n int) {
	if len(entries) > n {
		entries = entries[len(entries)-n:]
	}
	for _, e := range entries {
		at := e.At.Local().Format("2006-01-02 15:04:05")
		if e.Kind == "event" {
			_, _ = fmt.Fprintf(w, "%s  %s\n", at, e.Text)
			continue
		}
		outcome := "ok"
		if e.IsError {
			outcome = "error"
		}
		from := ""
		if e.Client != "" {
			from = " from " + e.Client
		}
		args := e.ArgumentsText()
		if r := []rune(args); len(r) > maxShown {
			args = string(r[:maxShown]) + "…"
		}
		_, _ = fmt.Fprintf(w, "%s  %s%s (%s, %d ms) %s\n", at, e.Tool, from, outcome, e.DurationMS, args)
	}
}

// Compare checks the log against the relay's audit entries over the same time (agent-protocol.md,
// "Audit comparison"): every relay call that reached the machine must be in the log, and every
// logged call among the relay's. running are call ids still in flight.
func Compare(log []Entry, relay []RelayEntry, running map[string]bool) (missingHere, missingThere []string) {
	logged := map[string]bool{}
	for _, e := range log {
		if e.Kind == "call" && e.CallID != "" {
			logged[e.CallID] = true
		}
	}
	audited := map[string]bool{}
	for _, r := range relay {
		if r.CallID == "" {
			continue
		}
		audited[r.CallID] = true
		if r.Outcome != "offline" && !logged[r.CallID] && !running[r.CallID] {
			missingHere = append(missingHere, r.CallID)
		}
	}
	for id := range logged {
		if !audited[id] {
			missingThere = append(missingThere, id)
		}
	}
	return missingHere, missingThere
}

// RelayEntry is one of the relay's audit entries for this machine.
type RelayEntry struct {
	CallID  string
	At      time.Time
	Outcome string
}

// auditSlack is how much earlier than the log's first call the relay's audit is asked for: the
// relay times a call as it sends it, before the server logs it (2026-11-04).
const auditSlack = 10 * time.Minute

// AuditSince is where the relay's audit is read from for a log whose first call is at start.
func AuditSince(start time.Time) time.Time { return start.Add(-auditSlack) }

// FromLogStart keeps the relay's entries from start on, and earlier ones only when the log has
// them (the log's first calls, timed a moment later here than at the relay).
func FromLogStart(relay []RelayEntry, start time.Time, log []Entry) []RelayEntry {
	logged := map[string]bool{}
	for _, e := range log {
		if e.Kind == "call" && e.CallID != "" {
			logged[e.CallID] = true
		}
	}
	var out []RelayEntry
	for _, r := range relay {
		if !r.At.Before(start) || logged[r.CallID] {
			out = append(out, r)
		}
	}
	return out
}

// Between returns the entries from from to to that keep accepts, oldest first, reading only the
// daily files of those days (spec 014 FR-1444: a problem report's part).
func (f Files) Between(from, to time.Time, keep func(*Entry) bool) ([]Entry, error) {
	days, _, err := f.days(from.UTC().Format(dayLayout), to.UTC().Format(dayLayout))
	if err != nil {
		return nil, err
	}
	var out []Entry
	for _, d := range days {
		err := scan(f.dayPath(d), func(b []byte, _ int64) {
			h, ok := decodeHead(b)
			if !ok || h.At.Before(from) || h.At.After(to) {
				return
			}
			e, ok := decode(b)
			if ok && keep(&e) {
				out = append(out, e)
			}
		})
		if err != nil {
			return nil, err
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].At.Before(out[j].At) })
	return out, nil
}

// Shown reports whether Claude may see the entry through latchkey_log (FR-1053).
func (e Entry) Shown() bool { return e.shown("") }

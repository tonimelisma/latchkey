// Package activity is the server's activity log (spec 010 FR-1050, FR-1051, plan D11): one JSON
// line per tool call and per event, in a file only the Owner's account can read. There are no
// notifications on a server; the log is read with `latchkey activity`, and compared with the
// relay's audit after each connection.
package activity

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"
)

// Entry is one line.
type Entry struct {
	At         time.Time `json:"at"`
	Kind       string    `json:"kind"`              // "call" or "event"
	CallID     string    `json:"call_id,omitempty"` // the relay's call id
	Tool       string    `json:"tool,omitempty"`
	Client     string    `json:"client,omitempty"` // the Claude app, as the relay names it
	Arguments  string    `json:"arguments,omitempty"`
	Result     string    `json:"result,omitempty"` // text, cut to maxResult
	IsError    bool      `json:"is_error,omitempty"`
	DurationMS int64     `json:"duration_ms,omitempty"`
	Text       string    `json:"text,omitempty"` // an event's words, for the Owner
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

const (
	maxArguments = 4000
	maxResult    = 2000
)

// MaxRecent is how many of this run's public events the log keeps in memory (FR-1055).
const MaxRecent = 1000

// Log appends entries.
type Log struct {
	mu     sync.Mutex
	path   string
	recent []Entry // this run's public events, oldest first
}

// Open opens (or creates) the log, readable only by the Owner.
func Open(path string) (*Log, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600) //nolint:gosec // the program's own log, in its data folder
	if err != nil {
		return nil, err
	}
	if err := errors.Join(f.Chmod(0o600), f.Close()); err != nil {
		return nil, err
	}
	return &Log{path: path}, nil
}

// Add writes an entry, cutting long arguments and results.
func (l *Log) Add(e Entry) error {
	e.Arguments = cut(e.Arguments, maxArguments)
	e.Result = cut(e.Result, maxResult)
	if e.At.IsZero() {
		e.At = time.Now()
	}
	e.At = e.At.UTC().Truncate(time.Millisecond)
	data, err := json.Marshal(e)
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
	f, err := os.OpenFile(l.path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	_, err = f.Write(append(data, '\n'))
	return errors.Join(err, f.Close())
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

// Public returns the log's newest n events Claude may see, of the category ("" any), oldest
// first (FR-1053): never a call, never an event without public words.
func Public(path, category string, n int) ([]Entry, error) {
	f, err := os.Open(path) //nolint:gosec // the program's own log, in its data folder
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	if n <= 0 {
		return nil, nil
	}
	ring := make([]Entry, 0, n)
	oldest := 0 // ring's oldest once it is full
	r := bufio.NewReader(f)
	for {
		line, err := r.ReadBytes('\n')
		if len(line) > 0 && bytes.Contains(line, []byte(`"public":`)) {
			var e Entry
			if json.Unmarshal(line, &e) == nil && e.shown(category) {
				if len(ring) < n {
					ring = append(ring, e)
				} else {
					ring[oldest] = e
					oldest = (oldest + 1) % n
				}
			}
		}
		if err == io.EOF {
			return append(ring[oldest:], ring[:oldest]...), nil
		}
		if err != nil {
			return nil, err
		}
	}
}

func cut(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}

// Read returns the entries at or after since, oldest first.
func Read(path string, since time.Time) ([]Entry, error) {
	f, err := os.Open(path) //nolint:gosec // the program's own log, in its data folder
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	var out []Entry
	r := bufio.NewReader(f)
	for {
		line, err := r.ReadBytes('\n')
		if len(line) > 0 {
			var e Entry
			if json.Unmarshal(line, &e) == nil && !e.At.Before(since) {
				out = append(out, e)
			}
		}
		if err == io.EOF {
			return out, nil
		}
		if err != nil {
			return out, err
		}
	}
}

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
		_, _ = fmt.Fprintf(w, "%s  %s%s (%s, %d ms) %s\n", at, e.Tool, from, outcome, e.DurationMS, e.Arguments)
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

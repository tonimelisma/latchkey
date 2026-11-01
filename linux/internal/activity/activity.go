// Package activity is the server's activity log (spec 010 FR-1050, FR-1051, plan D11): one JSON
// line per tool call and per event, in a file only the Owner's account can read. There are no
// notifications on a server; the log is read with `latchkey activity`, and compared with the
// relay's audit after each connection.
package activity

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
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
	Text       string    `json:"text,omitempty"` // an event's words
}

const (
	maxArguments = 4000
	maxResult    = 2000
)

// Log appends entries.
type Log struct {
	mu   sync.Mutex
	path string
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
	f, err := os.OpenFile(l.path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	_, err = f.Write(append(data, '\n'))
	return errors.Join(err, f.Close())
}

// Event records something that happened (connected, update installed, leftovers stopped).
func (l *Log) Event(format string, a ...any) {
	_ = l.Add(Entry{Kind: "event", Text: fmt.Sprintf(format, a...)})
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

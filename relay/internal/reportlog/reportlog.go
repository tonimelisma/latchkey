// Package reportlog keeps the relay's recent log lines about each account in memory, for that
// account's problem reports (spec 014 FR-1442): a slog.Handler that passes every record on to
// the relay's own handler and, for a record that names an account (the attribute "user"), keeps
// one line in a ring of that account's. Nothing here is ever written to disk; a line is
// forgotten after MaxAge, a ring holds at most PerAccount lines, and an account unheard of for
// MaxAge is dropped whole.
package reportlog

import (
	"context"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	// PerAccount is how many lines one account's ring holds.
	PerAccount = 500
	// MaxAge is how long a line is kept.
	MaxAge = 24 * time.Hour
	// maxLine bounds one kept line; the relay's lines are short, this only guards memory.
	maxLine = 2000
)

// Line is one kept log line.
type Line struct {
	Time time.Time
	Text string // "LEVEL message key=value …", without the account
}

// Ring holds the lines. The zero value isn't usable; use New.
type Ring struct {
	mu       sync.Mutex
	accounts map[string][]Line
	relay    []Line // the relay-wide lines (RelayWide), at most PerAccount
	now      func() time.Time
}

// New makes an empty ring set; now is the clock (nil: time.Now).
func New(now func() time.Time) *Ring {
	if now == nil {
		now = time.Now
	}
	return &Ring{accounts: map[string][]Line{}, now: now}
}

// Wrap returns a handler that writes to h and keeps account lines in r.
func (r *Ring) Wrap(h slog.Handler) slog.Handler { return &handler{next: h, ring: r} }

// Lines are the account's lines from since on, with the relay-wide ones (RelayWide), oldest
// first.
func (r *Ring) Lines(account string, since time.Time) []Line {
	if r == nil {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []Line
	cutoff := r.now().Add(-MaxAge)
	for _, ls := range [][]Line{r.accounts[account], r.relay} {
		for _, l := range ls {
			if !l.Time.Before(since) && l.Time.After(cutoff) {
				out = append(out, l)
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Time.Before(out[j].Time) })
	return out
}

// Forget drops an account's lines (the account was deleted).
func (r *Ring) Forget(account string) {
	r.mu.Lock()
	delete(r.accounts, account)
	r.mu.Unlock()
}

func (r *Ring) keepRelayWide(l Line) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.relay = append(r.relay, l)
	if len(r.relay) > PerAccount {
		r.relay = append([]Line(nil), r.relay[len(r.relay)-PerAccount:]...)
	}
}

func (r *Ring) keep(account string, l Line) {
	r.mu.Lock()
	defer r.mu.Unlock()
	lines := r.accounts[account]
	lines = append(lines, l)
	cutoff := l.Time.Add(-MaxAge)
	drop := 0
	for drop < len(lines) && (len(lines)-drop > PerAccount || lines[drop].Time.Before(cutoff)) {
		drop++
	}
	r.accounts[account] = append([]Line(nil), lines[drop:]...)
	// Now and then, drop accounts unheard of for a day, so the map can't grow without bound.
	if len(r.accounts)%64 == 0 {
		for id, ls := range r.accounts {
			if len(ls) == 0 || ls[len(ls)-1].Time.Before(cutoff) {
				delete(r.accounts, id)
			}
		}
	}
}

// AccountKey is the attribute that names an account in the relay's log lines.
const AccountKey = "user"

// RelayWide is the attribute (true) that marks a line about the relay itself, not one account:
// its start (with its version) and its shutdown. Every account's report holds these lines, so a
// call that failed while the relay restarted can be told from one Latchkey lost (spec 014
// FR-1442a). Only lines that name no account, machine, or address may carry it.
const RelayWide = "relay_wide"

type handler struct {
	next  slog.Handler
	ring  *Ring
	attrs []slog.Attr // from WithAttrs, without groups (the relay uses none)
	group string
}

func (h *handler) Enabled(ctx context.Context, l slog.Level) bool {
	return h.next.Enabled(ctx, l) || l >= slog.LevelInfo
}

func (h *handler) Handle(ctx context.Context, rec slog.Record) error {
	account := ""
	relayWide := false
	var b strings.Builder
	b.WriteString(rec.Level.String())
	b.WriteString(" ")
	b.WriteString(rec.Message)
	add := func(a slog.Attr) {
		switch {
		case a.Key == AccountKey && h.group == "":
			account = a.Value.String()
			return
		case a.Key == RelayWide && h.group == "":
			relayWide = a.Value.Kind() == slog.KindBool && a.Value.Bool()
			return
		}
		fmt.Fprintf(&b, " %s=%s", a.Key, a.Value.String())
	}
	for _, a := range h.attrs {
		add(a)
	}
	rec.Attrs(func(a slog.Attr) bool { add(a); return true })
	text := b.String()
	if len(text) > maxLine {
		text = text[:maxLine]
	}
	line := Line{Time: h.ring.now().UTC(), Text: text} // the ring's clock, as Lines reads it
	switch {
	case account != "" && rec.Level >= slog.LevelInfo:
		h.ring.keep(account, line)
	case relayWide && account == "":
		// Only the message and the version go into every account's report, whatever else the
		// line carries: no account's, machine's, or address's detail can get there (security
		// review 2026-11-27).
		wide := rec.Level.String() + " " + rec.Message
		rec.Attrs(func(a slog.Attr) bool {
			if a.Key == "version" {
				wide += " version=" + a.Value.String()
			}
			return true
		})
		if len(wide) > maxLine {
			wide = wide[:maxLine]
		}
		h.ring.keepRelayWide(Line{Time: line.Time, Text: wide})
	}
	if !h.next.Enabled(ctx, rec.Level) {
		return nil
	}
	return h.next.Handle(ctx, rec)
}

func (h *handler) WithAttrs(as []slog.Attr) slog.Handler {
	return &handler{next: h.next.WithAttrs(as), ring: h.ring, attrs: append(append([]slog.Attr(nil), h.attrs...), as...), group: h.group}
}

func (h *handler) WithGroup(name string) slog.Handler {
	return &handler{next: h.next.WithGroup(name), ring: h.ring, attrs: h.attrs, group: name}
}

package activity

import (
	"bufio"
	"cmp"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"sort"
)

// exported is the export line every side writes (spec 001 FR-686; trace-files.md "The export
// line"), fields in the contract's order.
type exported struct {
	V          int             `json:"v"`
	Source     string          `json:"source"`
	Machine    string          `json:"machine"`
	Time       string          `json:"time"`
	Kind       string          `json:"kind"`
	Tool       string          `json:"tool"`
	Arguments  json.RawMessage `json:"arguments"`
	Result     json.RawMessage `json:"result"`
	IsError    bool            `json:"isError"`
	DurationMS int64           `json:"durationMS"`
	CallID     *string         `json:"call_id"`
	Client     *string         `json:"client"`
}

// Export writes the log from day from to day to (YYYY-MM-DD in UTC, both included; "" open) in
// the export line, oldest first, machine naming this server; the old file's lines too. It
// returns how many lines it wrote and how many of the log's lines couldn't be read. It holds one
// day's entries' times in memory at a time, not their content.
func (f Files) Export(w io.Writer, machine, from, to string) (written, skipped int, err error) {
	for _, d := range []string{from, to} {
		if d != "" && !isDay(d) {
			return 0, 0, fmt.Errorf("%q isn't a day: give it as YYYY-MM-DD", d)
		}
	}
	if from != "" && to != "" && from > to {
		return 0, 0, errors.New("the first day is after the last")
	}
	days, old, err := f.days(from, to)
	if err != nil {
		return 0, 0, err
	}
	inRange := func(day string) bool { return (from == "" || day >= from) && (to == "" || day <= to) }
	// The old file is small (its lines were cut short): its entries in the range, by day.
	byDay := map[string][]Entry{}
	if old {
		err := scan(f.Old, func(b []byte, _ int64) {
			e, ok := decode(b)
			if !ok {
				skipped++
				return
			}
			if day := e.At.UTC().Format(dayLayout); inRange(day) {
				byDay[day] = append(byDay[day], e)
			}
		})
		if err != nil {
			return 0, skipped, err
		}
	}
	all := slices.Clone(days)
	for day := range byDay {
		all = append(all, day)
	}
	slices.Sort(all)
	all = slices.Compact(all)

	bw := bufio.NewWriterSize(w, 64<<10)
	enc := json.NewEncoder(bw)
	enc.SetEscapeHTML(false)
	for _, day := range all {
		n, s, err := f.exportDay(enc, machine, day, byDay[day], slices.Contains(days, day))
		written += n
		skipped += s
		if err != nil {
			return written, skipped, errors.Join(err, bw.Flush())
		}
	}
	return written, skipped, bw.Flush()
}

// exportDay writes one day: the old file's entries of the day and the day's file, ordered by
// when each began (a long call is written when it ends, after later ones).
func (f Files) exportDay(enc *json.Encoder, machine, day string, olds []Entry, hasFile bool) (written, skipped int, err error) {
	type item struct {
		at     int64  // when it began, for the order
		e      *Entry // an old file's entry; nil: read it from the day's file
		off    int64
		length int
	}
	var items []item
	for i := range olds {
		items = append(items, item{at: olds[i].At.UnixNano(), e: &olds[i]})
	}
	path := f.dayPath(day)
	if hasFile {
		err := scan(path, func(b []byte, off int64) {
			h, ok := decodeHead(b)
			if !ok {
				skipped++
				return
			}
			items = append(items, item{at: h.At.UnixNano(), off: off, length: len(b)})
		})
		if err != nil {
			return 0, skipped, err
		}
	}
	sort.SliceStable(items, func(a, b int) bool { return items[a].at < items[b].at })
	var file *os.File
	if hasFile {
		if file, err = os.Open(path); err != nil { //nolint:gosec // the program's own log, in its data folder
			return 0, skipped, err
		}
		defer func() { _ = file.Close() }()
	}
	for _, it := range items {
		e := it.e
		if e == nil {
			buf := make([]byte, it.length)
			if n, err := file.ReadAt(buf, it.off); n != len(buf) {
				return written, skipped, cmp.Or(err, io.ErrUnexpectedEOF)
			}
			read, ok := decode(buf)
			if !ok {
				skipped++
				continue
			}
			e = &read
		}
		if err := enc.Encode(exportLine(e, machine)); err != nil {
			return written, skipped, err
		}
		written++
	}
	return written, skipped, nil
}

func exportLine(e *Entry, machine string) exported {
	x := exported{V: Version, Source: "linux", Machine: machine, Time: e.At.UTC().Format(timeLayout), IsError: e.IsError}
	if e.Kind == "event" {
		x.Kind, x.Tool = "event", cmp.Or(e.Category, "event")
		x.Arguments, x.Result = quote(""), quote(e.Text)
		return x
	}
	x.Kind, x.Tool, x.DurationMS = "action", e.Tool, e.DurationMS
	if e.V == 0 {
		// Version 0 kept text, cut short: arguments that are still JSON stay JSON; the result was
		// the content's text, never the content array, so it stays text.
		x.Arguments, x.Result = embedded(text(e.Arguments)), quote(text(e.Result))
	} else {
		x.Arguments, x.Result = orNull(e.Arguments), orNull(e.Result)
	}
	if e.CallID != "" {
		x.CallID = &e.CallID
	}
	if e.Client != "" {
		x.Client = &e.Client
	}
	return x
}

// embedded is text that is JSON as that JSON, anything else as a string.
func embedded(s string) json.RawMessage {
	if s != "" && json.Valid([]byte(s)) {
		return json.RawMessage(s)
	}
	return quote(s)
}

func orNull(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 {
		return json.RawMessage("null")
	}
	return raw
}

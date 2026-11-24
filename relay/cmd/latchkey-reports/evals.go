package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"sort"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/evals"
	"github.com/tonimelisma/latchkey/relay/reports"
)

// Reminder is the line a session tells Toni when no weekly result arrived this week (spec 015
// FR-1511).
const Reminder = "The weekly test run hasn't run this week: on your Mac, run macos/scripts/weekly-eval.sh --send in Terminal from the repository (about an hour; nothing to approve)."

// weeklyRun is one weekly run as the developer reads it: its parts joined, compared with the run before.
type weeklyRun struct {
	Run        string            `json:"run"`
	IDs        []string          `json:"ids"` // the intake entries to delete once dispositioned
	Started    time.Time         `json:"started"`
	Latchkey   string            `json:"latchkey,omitempty"`
	Summary    evals.Summary     `json:"summary"`
	Comparison *evals.Comparison `json:"comparison,omitempty"`
	Result     *evals.Result     `json:"result,omitempty"`
	Error      string            `json:"error,omitempty"`
}

func evalsCmd(args []string, now time.Time, w io.Writer) error {
	fs := flag.NewFlagSet("evals", flag.ContinueOnError)
	thisWeek := fs.Bool("this-week", false, "say whether a result arrived this week (Monday to Sunday)")
	quiet := fs.Bool("quiet", false, "with -this-week: print only the reminder, when none arrived")
	if err := fs.Parse(args); err != nil {
		return err
	}
	entries, err := fetch()
	if err != nil {
		return err
	}
	runs := joinRuns(entries)
	if *thisWeek {
		start := weekStart(now)
		for _, r := range runs {
			if !r.Started.Before(start) && r.Error == "" {
				if !*quiet {
					_, err := fmt.Fprintf(w, "this week's run: %s (%s)\n", r.Run, r.Started.Format(time.RFC3339))
					return err
				}
				return nil
			}
		}
		_, err := fmt.Fprintln(w, Reminder)
		return err
	}
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(runs)
}

// joinRuns groups the weekly results' parts by run, oldest first, each compared with the one
// before it.
func joinRuns(entries []entry) []weeklyRun {
	parts := map[string][]evals.Result{}
	ids := map[string][]string{}
	for _, e := range entries {
		if e.Err != nil || reports.Kind(e.Plain) != "eval" {
			continue
		}
		var r evals.Result
		if json.Unmarshal(e.Plain, &r) != nil {
			continue
		}
		parts[r.Run] = append(parts[r.Run], r)
		ids[r.Run] = append(ids[r.Run], e.ID)
	}
	var out []weeklyRun
	for name, ps := range parts {
		joined, err := evals.Join(ps)
		r := weeklyRun{Run: name, IDs: ids[name], Started: ps[0].Started, Latchkey: ps[0].Latchkey}
		if err != nil {
			r.Error = err.Error()
		} else {
			r.Result = &joined
			r.Summary = joined.Summarize()
		}
		out = append(out, r)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Started.Before(out[j].Started) })
	var prev *evals.Result
	for i := range out {
		if out[i].Result == nil {
			continue
		}
		c := evals.Compare(prev, *out[i].Result)
		out[i].Comparison = &c
		prev = out[i].Result
	}
	return out
}

// weekStart is the Monday 00:00 of now's week, in now's time zone.
func weekStart(now time.Time) time.Time {
	d := (int(now.Weekday()) + 6) % 7 // days since Monday
	y, m, day := now.AddDate(0, 0, -d).Date()
	return time.Date(y, m, day, 0, 0, 0, 0, now.Location())
}


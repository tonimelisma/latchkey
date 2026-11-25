package main

import (
	"encoding/json"
	"flag"
	"io"
	"sort"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/evals"
	"github.com/tonimelisma/latchkey/relay/reports"
)

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
	// No -this-week reminder: there is no weekly run (Toni, 2026-11-25; spec 015 FR-1511 withdrawn).
	fs := flag.NewFlagSet("evals", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return err
	}
	entries, err := fetch()
	if err != nil {
		return err
	}
	private, err := keyText()
	if err != nil {
		return err
	}
	runs := joinRuns(entries, evals.SignKey(private), now)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(runs)
}

// joinRuns groups the weekly results' parts by run, oldest first, each compared with the one
// before it. A run whose parts aren't signed with the developer's key is listed with the error
// and counts for nothing (anyone can post to the intake).
func joinRuns(entries []entry, signKey []byte, now time.Time) []weeklyRun {
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
		joined, err := evals.Join(ps, signKey, now)
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

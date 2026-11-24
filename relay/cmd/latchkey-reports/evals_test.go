package main

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/evals"
)

var testSign = evals.SignKey("the developer's key, for the test")

func evalEntry(t *testing.T, id string, r evals.Result) entry {
	t.Helper()
	if err := r.Sign(testSign); err != nil {
		t.Fatal(err)
	}
	b, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	return entry{ID: id, Plain: b}
}

func TestJoinRuns(t *testing.T) {
	week1 := time.Date(2026, 11, 16, 21, 0, 0, 0, time.UTC)
	week2 := week1.AddDate(0, 0, 7)
	pass := evals.TaskResult{ID: "files.a", PassAll: true, PassAny: true, Passes: 3, Of: 3}
	fail := evals.TaskResult{ID: "files.a", Passes: 0, Of: 3}
	entries := []entry{
		{ID: "rep_report", Plain: []byte(`{"format":2,"summary":"a problem report"}`)},
		evalEntry(t, "rep_1", evals.Result{Kind: "eval", Run: "ev_1", Part: 1, Parts: 1, Started: week1, Tasks: []evals.TaskResult{pass}}),
		evalEntry(t, "rep_2b", evals.Result{Kind: "eval", Run: "ev_2", Part: 2, Parts: 2, Started: week2, Tasks: []evals.TaskResult{{ID: "files.b", PassAny: true, Passes: 1, Of: 3}}}),
		evalEntry(t, "rep_2a", evals.Result{Kind: "eval", Run: "ev_2", Part: 1, Parts: 2, Started: week2, Tasks: []evals.TaskResult{fail}}),
		evalEntry(t, "rep_3", evals.Result{Kind: "eval", Run: "ev_3", Part: 1, Parts: 2, Started: week2}),
		forged(t, "rep_4", evals.Result{Kind: "eval", Run: "ev_4", Part: 1, Parts: 1, Started: week2}),
	}
	runs := joinRuns(entries, testSign, week2.Add(time.Hour))
	if len(runs) != 4 || runs[0].Run != "ev_1" {
		t.Fatalf("%+v", runs)
	}
	var two weeklyRun
	for _, r := range runs {
		if r.Run == "ev_2" {
			two = r
		}
		if r.Run == "ev_3" && r.Error == "" {
			t.Error("a run missing a part isn't flagged")
		}
		if r.Run == "ev_4" && (r.Error == "" || r.Result != nil) {
			t.Error("a result not signed with the developer's key counted (anyone can post to the intake)")
		}
	}
	if len(two.IDs) != 2 || two.Summary.Tasks != 2 || two.Comparison == nil ||
		len(two.Comparison.NewFailures) != 1 || len(two.Comparison.Flaky) != 1 {
		t.Fatalf("run 2: %+v %+v", two, two.Comparison)
	}
}

func TestWeekStart(t *testing.T) {
	sun := time.Date(2026, 11, 29, 23, 0, 0, 0, time.UTC) // a Sunday
	if got := weekStart(sun); got.Weekday() != time.Monday || got.Day() != 23 {
		t.Fatalf("%v", got)
	}
	mon := time.Date(2026, 11, 23, 0, 30, 0, 0, time.UTC)
	if got := weekStart(mon); got.Day() != 23 {
		t.Fatalf("%v", got)
	}
}

// forged is a result someone without the developer's key sealed and posted.
func forged(t *testing.T, id string, r evals.Result) entry {
	t.Helper()
	if err := r.Sign(evals.SignKey("not the developer's")); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(r)
	return entry{ID: id, Plain: b}
}

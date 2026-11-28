package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/evals"
)

// Every fixture line in the repository's tasks names a set or check this program knows, and every
// case a task covers has its row in docs/regression-coverage.md naming that task (FR-1525).
func TestTaskLinesAreKnown(t *testing.T) {
	tasks, err := evals.LoadTasks(filepath.Join("..", "..", "e2e", "tasks"))
	if err != nil {
		t.Fatal(err)
	}
	knownChecks := []string{
		"files contains", "files lacks", "files exists", "files missing", "files untouched", "files same-as",
		"files zip-lists", "files downloaded", "notes exists", "notes missing", "notes body-contains",
		"calendar event-at", "calendar count", "reminders exists", "reminders completed", "reminders not-completed",
		"reminders due-on", "contacts has-email", "pages got", "pages not-got",
	}
	sets := map[string][]string{
		"files": keys(fileSets), "notes": {"shopping", "recipe-injected"}, "calendar": {"team-sync", "empty"},
		"reminders": {"chores", "empty"}, "contacts": {"jordan"}, "pages": {"rsvp", "bank", "orders", "news"},
	}
	rows := coverageRows(t)
	for _, tk := range tasks {
		lines := append(append(append([]string{}, tk.Setup...), tk.Check...), tk.Cleanup...)
		if tk.Injected != nil {
			lines = append(lines, tk.Injected.MustNot...)
		}
		for _, l := range lines {
			w, err := evals.Words(l)
			if err != nil {
				t.Fatalf("%s: %v", tk.ID, err)
			}
			switch w[0] {
			case "check":
				if len(w) < 3 || !slices.Contains(knownChecks, w[1]+" "+w[2]) {
					t.Errorf("%s: unknown check %q", tk.ID, l)
				}
			case "fixture":
				if len(w) != 3 || !slices.Contains(sets[w[1]], w[2]) {
					t.Errorf("%s: unknown fixture %q", tk.ID, l)
				}
			case "sweep":
				if _, ok := sets[w[1]]; !ok || len(w) != 2 {
					t.Errorf("%s: unknown sweep %q", tk.ID, l)
				}
			}
		}
		for _, c := range tk.Covers {
			row, ok := rows[strings.TrimPrefix(c, "regressions.")]
			switch {
			case !ok:
				t.Errorf("%s covers %s, which has no row in docs/regression-coverage.md", tk.ID, c)
			case !strings.Contains(row, "eval task `"+tk.ID+"`"):
				t.Errorf("%s covers %s, whose row in docs/regression-coverage.md doesn't name the task", tk.ID, c)
			}
		}
	}
}

func keys[V any](m map[string]V) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	return out
}

// coverageRows returns each case's table row in docs/regression-coverage.md, by the case's id.
func coverageRows(t *testing.T) map[string]string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "docs", "regression-coverage.md"))
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]string{}
	for line := range strings.Lines(string(data)) {
		rest, ok := strings.CutPrefix(line, "| `")
		if !ok {
			continue
		}
		if id, _, ok := strings.Cut(rest, "` |"); ok {
			out[id] = line
		}
	}
	if len(out) == 0 {
		t.Fatal("no case rows in docs/regression-coverage.md")
	}
	return out
}

func TestDays(t *testing.T) {
	for word, want := range map[string]int{"today": 0, "tomorrow": 1, "in-2-days": 2} {
		if got, err := dayOffset(word); err != nil || got != want {
			t.Errorf("%s: %d %v", word, got, err)
		}
	}
	if _, err := dayOffset("next tuesday"); err == nil {
		t.Error("an unknown day accepted")
	}
	d, _ := dueDay("first-of-next-month")
	n := time.Now()
	first := time.Date(n.Year(), n.Month()+1, 1, 0, 0, 0, 0, n.Location())
	if !strings.HasSuffix(d, "-1") || !strings.HasPrefix(d, first.Format("2006")) {
		t.Errorf("first of next month: %s", d)
	}
}

// Files fixtures, checks and sweeps work on any system (no Apple apps): run them in a temporary
// home.
func TestFilesFixtures(t *testing.T) {
	f := &fixtures{home: t.TempDir(), start: time.Now().Add(-time.Second)}
	for _, l := range []string{"fixture files invoice", "fixture files photos"} {
		if err := f.do(l); err != nil {
			t.Fatal(l, err)
		}
	}
	ok := func(l string) {
		t.Helper()
		if c := f.check(l); !c.OK {
			t.Errorf("%s: %s", l, c.Why)
		}
	}
	bad := func(l string) {
		t.Helper()
		if c := f.check(l); c.OK {
			t.Errorf("%s passed", l)
		}
	}
	ok("check files contains invoice-0457.txt 'TOTAL DUE'")
	ok("check files untouched invoice-0457.txt")
	bad("check files missing invoice-0457.txt")
	bad("check files same-as photos/a.png photos/b.png")
	p := filepath.Join(f.root(), "invoice-0457.txt")
	if err := os.WriteFile(p, []byte("changed"), 0o600); err != nil {
		t.Fatal(err)
	}
	bad("check files untouched invoice-0457.txt")
	bad("check files nonsense x")
	if c := f.check("check files nonsense x"); !strings.HasPrefix(c.Why, "couldn't check") {
		t.Errorf("an unknown check says it couldn't check: %q", c.Why)
	}
	dl := filepath.Join(f.home, "Downloads")
	_ = os.MkdirAll(dl, 0o750)
	_ = os.WriteFile(filepath.Join(dl, "statement-october.txt"), []byte("LatchkeyEval marker october"), 0o600)
	ok("check files downloaded statement-october 'marker october'")
	if err := f.do("sweep files"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(f.root()); !os.IsNotExist(err) {
		t.Error("sweep left the folder")
	}
	if _, err := os.Stat(filepath.Join(dl, "statement-october.txt")); !os.IsNotExist(err) {
		t.Error("sweep left the downloaded test file")
	}
}

// The requirements this file's tests cite (docs/requirements/; script/process-check).
// Validates: FR-1525

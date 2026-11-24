package evals

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Task is one eval task (contracts/task-format.md, FR-1520).
type Task struct {
	ID         string   `json:"id"`
	Capability string   `json:"capability"`
	Covers     []string `json:"covers,omitempty"`
	// Instruction is what the owner would write in a chat.
	Instruction string `json:"instruction"`
	// Setup, Check and Cleanup are fixture lines ("fixture notes shopping-list",
	// "check files contains LatchkeyEval/total.txt 412.50", "sweep notes").
	Setup   []string `json:"setup"`
	Check   []string `json:"check"`
	Cleanup []string `json:"cleanup"`
	// Required calls are reported when missing; Forbidden calls fail the try; Unneeded calls
	// are reported (FR-1521).
	Required  []string   `json:"required_calls,omitempty"`
	Forbidden []CallRule `json:"forbidden_calls,omitempty"`
	Unneeded  []string   `json:"unneeded_calls,omitempty"`
	Injected  *Injected  `json:"injected,omitempty"`
	MaxTurns  int        `json:"max_turns"`
	// HeldOut is set by the loader for tasks under held-out/ (FR-1526).
	HeldOut bool `json:"-"`
}

// Injected is a task whose test data plants an instruction (FR-1524): planted by its setup lines,
// it passes only if none of MustNotCalls was made and every MustNot check passes.
type Injected struct {
	MustNotCalls []CallRule `json:"must_not_calls,omitempty"`
	MustNot      []string   `json:"must_not,omitempty"`
}

// CallRule matches a tool call: the tool's name, and optionally arguments whose text contains
// the given text. Written as a plain string (the tool) or {"tool": ..., "args_match": {...}}.
type CallRule struct {
	Tool      string            `json:"tool"`
	ArgsMatch map[string]string `json:"args_match,omitempty"`
}

// UnmarshalJSON takes a plain tool name too.
func (r *CallRule) UnmarshalJSON(b []byte) error {
	var name string
	if json.Unmarshal(b, &name) == nil {
		r.Tool = name
		return nil
	}
	type plain CallRule
	return json.Unmarshal(b, (*plain)(r))
}

// Matches says whether a call breaks the rule.
func (r CallRule) Matches(c Call) bool {
	if r.Tool != c.Tool {
		return false
	}
	if len(r.ArgsMatch) == 0 {
		return true
	}
	var args map[string]any
	_ = json.Unmarshal(c.Input, &args)
	for k, want := range r.ArgsMatch {
		got, ok := args[k]
		if !ok {
			return false
		}
		text, isText := got.(string)
		if !isText {
			b, _ := json.Marshal(got)
			text = string(b)
		}
		if !strings.Contains(strings.ToLower(text), strings.ToLower(want)) {
			return false
		}
	}
	return true
}

var (
	taskID    = regexp.MustCompile(`^[a-z]+\.[a-z0-9-]+$`)
	fixtureRE = regexp.MustCompile(`^(fixture|check|sweep) [a-z]+( .*)?$`)
)

// LoadTasks reads every task under dir (held-out ones under dir/held-out) and checks them.
func LoadTasks(dir string) ([]Task, error) {
	var tasks []Task
	seen := map[string]bool{}
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(p, ".json") {
			return err
		}
		data, err := os.ReadFile(p) //nolint:gosec // the repository's tasks
		if err != nil {
			return err
		}
		var t Task
		dec := json.NewDecoder(strings.NewReader(string(data)))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&t); err != nil {
			return fmt.Errorf("%s: %w", p, err)
		}
		rel, _ := filepath.Rel(dir, p)
		t.HeldOut = strings.HasPrefix(filepath.ToSlash(rel), "held-out/")
		if err := t.validate(); err != nil {
			return fmt.Errorf("%s: %w", p, err)
		}
		if seen[t.ID] {
			return fmt.Errorf("%s: task id %s used twice", p, t.ID)
		}
		seen[t.ID] = true
		tasks = append(tasks, t)
		return nil
	})
	sort.Slice(tasks, func(i, j int) bool { return tasks[i].ID < tasks[j].ID })
	return tasks, err
}

func (t Task) validate() error {
	var errs []error
	if !taskID.MatchString(t.ID) {
		errs = append(errs, fmt.Errorf("id %q isn't area.name", t.ID))
	}
	if strings.TrimSpace(t.Instruction) == "" {
		errs = append(errs, errors.New("no instruction"))
	}
	if len(t.Check) == 0 {
		errs = append(errs, errors.New("no check: a task is scored on the end state (FR-1521)"))
	}
	if t.MaxTurns < 1 || t.MaxTurns > 60 {
		errs = append(errs, fmt.Errorf("max_turns %d isn't 1 to 60", t.MaxTurns))
	}
	lines := append(append(append([]string{}, t.Setup...), t.Check...), t.Cleanup...)
	if t.Injected != nil {
		lines = append(lines, t.Injected.MustNot...)
		if len(t.Injected.MustNot)+len(t.Injected.MustNotCalls) == 0 {
			errs = append(errs, errors.New("injected without must_not or must_not_calls"))
		}
	}
	for _, l := range lines {
		if !fixtureRE.MatchString(l) {
			errs = append(errs, fmt.Errorf("fixture line %q isn't \"fixture|check|sweep <area> ...\"", l))
		}
	}
	for _, l := range t.Check {
		if !strings.HasPrefix(l, "check ") {
			errs = append(errs, fmt.Errorf("check line %q doesn't start with check", l))
		}
	}
	if len(t.Cleanup) == 0 {
		errs = append(errs, errors.New("no cleanup: a task removes what it made"))
	}
	return errors.Join(errs...)
}

// Words splits a fixture line into words; 'single quotes' keep spaces.
func Words(line string) ([]string, error) {
	var out []string
	var cur strings.Builder
	in, has := false, false
	for _, r := range line {
		switch {
		case r == '\'':
			in = !in
			has = true
		case r == ' ' && !in:
			if has {
				out = append(out, cur.String())
				cur.Reset()
				has = false
			}
		default:
			cur.WriteRune(r)
			has = true
		}
	}
	if in {
		return nil, fmt.Errorf("unclosed quote in %q", line)
	}
	if has {
		out = append(out, cur.String())
	}
	return out, nil
}

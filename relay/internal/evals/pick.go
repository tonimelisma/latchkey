// Package evals is spec 015's end-to-end tests and evals: which checks a pull request's changed
// files select (FR-1500), tool snapshots (FR-1504), eval tasks and their scoring (FR-1520 to
// FR-1526), Claude Code's stream as an eval reads it, and the weekly result (FR-1530).
package evals

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"slices"
	"sort"
	"strings"
)

// Map is relay/e2e/capabilities.json: path globs to capabilities, each with its checks.
type Map struct {
	Shared       []string              `json:"shared"`
	Capabilities map[string]Capability `json:"capabilities"`
}

// Capability is one area's end-to-end checks on a runner.
type Capability struct {
	// Runner is "linux" (GitHub's Ubuntu runner) or "mac" (GitHub's macOS runner).
	Runner string `json:"runner"`
	// Checks are the check names the runner's job runs; none means Skip says why (FR-1506).
	Checks []string `json:"checks"`
	Skip   string   `json:"skip,omitempty"`
	Paths  []string `json:"paths"`
	// Selects are other capabilities a change here selects too (the Mac app's core).
	Selects []string `json:"selects,omitempty"`
}

// LoadMap reads and checks the map.
func LoadMap(path string) (*Map, error) {
	data, err := os.ReadFile(path) //nolint:gosec // the repository's own file
	if err != nil {
		return nil, err
	}
	var m Map
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	for name, c := range m.Capabilities {
		if c.Runner != "linux" && c.Runner != "mac" {
			return nil, fmt.Errorf("%s: capability %s: runner %q isn't linux or mac", path, name, c.Runner)
		}
		if len(c.Checks) == 0 && c.Skip == "" {
			return nil, fmt.Errorf("%s: capability %s has no checks and no reason to skip", path, name)
		}
		for _, s := range c.Selects {
			if _, ok := m.Capabilities[s]; !ok {
				return nil, fmt.Errorf("%s: capability %s selects unknown %s", path, name, s)
			}
		}
		for _, g := range c.Paths {
			if _, err := globRE(g); err != nil {
				return nil, fmt.Errorf("%s: capability %s: %w", path, name, err)
			}
		}
	}
	return &m, nil
}

// Selection is what a set of changed files selects.
type Selection struct {
	// Capabilities selected, sorted.
	Capabilities []string `json:"capabilities"`
	// Checks per runner ("linux", "mac"), sorted, without repeats.
	Checks map[string][]string `json:"checks"`
	// Skipped capabilities with their reason (FR-1506).
	Skipped map[string]string `json:"skipped,omitempty"`
}

// Has says whether runner has any check to run.
func (s Selection) Has(runner string) bool { return len(s.Checks[runner]) > 0 }

// Select returns what the changed files select (FR-1500): a shared path selects everything.
func (m *Map) Select(changed []string) Selection {
	picked := map[string]bool{}
	all := false
	for _, f := range changed {
		if matchAny(m.Shared, f) {
			all = true
			break
		}
		for name, c := range m.Capabilities {
			if matchAny(c.Paths, f) {
				picked[name] = true
			}
		}
	}
	if all {
		for name := range m.Capabilities {
			picked[name] = true
		}
	}
	for name := range picked {
		for _, s := range m.Capabilities[name].Selects {
			picked[s] = true
		}
	}
	sel := Selection{Checks: map[string][]string{"linux": {}, "mac": {}}, Skipped: map[string]string{}}
	for name := range picked {
		c := m.Capabilities[name]
		sel.Capabilities = append(sel.Capabilities, name)
		if len(c.Checks) == 0 {
			sel.Skipped[name] = c.Skip
			continue
		}
		sel.Checks[c.Runner] = append(sel.Checks[c.Runner], c.Checks...)
	}
	// Any Mac capability brings the Mac's shared checks (pairing, a capability turned off, the
	// offline answer, the snapshots).
	if len(sel.Checks["mac"]) > 0 || anySkippedMac(m, sel) {
		sel.Checks["mac"] = append(sel.Checks["mac"], m.Capabilities["mac"].Checks...)
	}
	sort.Strings(sel.Capabilities)
	for r, cs := range sel.Checks {
		sort.Strings(cs)
		sel.Checks[r] = slices.Compact(cs)
	}
	return sel
}

// anySkippedMac: a change to a Mac capability with no runner checks still changes the Mac's
// tool list, which the core check snapshots.
func anySkippedMac(m *Map, sel Selection) bool {
	for name := range sel.Skipped {
		if m.Capabilities[name].Runner == "mac" {
			return true
		}
	}
	return false
}

// Unmatched returns the files no glob in the map matches.
func (m *Map) Unmatched(files []string) []string {
	var out []string
	for _, f := range files {
		if matchAny(m.Shared, f) {
			continue
		}
		hit := false
		for _, c := range m.Capabilities {
			if matchAny(c.Paths, f) {
				hit = true
				break
			}
		}
		if !hit {
			out = append(out, f)
		}
	}
	return out
}

func matchAny(globs []string, f string) bool {
	for _, g := range globs {
		if re, err := globRE(g); err == nil && re.MatchString(f) {
			return true
		}
	}
	return false
}

// globRE turns a path glob into a regular expression: ** is any number of folders, * anything
// but a slash, ? one character but a slash.
func globRE(g string) (*regexp.Regexp, error) {
	if g == "" || strings.HasPrefix(g, "/") {
		return nil, fmt.Errorf("glob %q must be a relative path", g)
	}
	var b strings.Builder
	b.WriteString("^")
	for i := 0; i < len(g); i++ {
		switch c := g[i]; {
		case c == '*' && i+1 < len(g) && g[i+1] == '*':
			i++
			if i+1 < len(g) && g[i+1] == '/' {
				i++
				b.WriteString("(?:.*/)?")
			} else {
				b.WriteString(".*")
			}
		case c == '*':
			b.WriteString("[^/]*")
		case c == '?':
			b.WriteString("[^/]")
		default:
			b.WriteString(regexp.QuoteMeta(string(c)))
		}
	}
	b.WriteString("$")
	return regexp.Compile(b.String())
}

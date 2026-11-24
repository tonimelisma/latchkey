package evals

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// toolName is what a snapshot file may be called: tool names are plain words.
var toolName = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)

// SnapshotJSON is a tool as Claude sees it, canonical (keys sorted, indented), for its snapshot
// file (FR-1504).
func SnapshotJSON(t *mcp.Tool) ([]byte, error) {
	raw, err := json.Marshal(t)
	if err != nil {
		return nil, err
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return nil, err
	}
	out, err := json.MarshalIndent(v, "", "  ") // maps marshal with sorted keys
	if err != nil {
		return nil, err
	}
	return append(out, '\n'), nil
}

// SnapDiff is one difference between the tools and their snapshots.
type SnapDiff struct {
	Tool   string
	Change string // "added", "removed", "changed"
}

func (d SnapDiff) String() string { return d.Tool + " " + d.Change }

// CompareSnapshots compares tools with the snapshot files in dir (one <name>.json per tool). With
// update, it rewrites dir to match and still returns what differed.
func CompareSnapshots(dir string, tools []*mcp.Tool, update bool) ([]SnapDiff, error) {
	want := map[string][]byte{}
	for _, t := range tools {
		if !toolName.MatchString(t.Name) {
			return nil, fmt.Errorf("tool name %q can't be a snapshot file name", t.Name)
		}
		b, err := SnapshotJSON(t)
		if err != nil {
			return nil, err
		}
		want[t.Name] = b
	}
	have := map[string][]byte{}
	entries, err := os.ReadDir(dir)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	for _, e := range entries {
		name, ok := strings.CutSuffix(e.Name(), ".json")
		if !ok || e.IsDir() {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, e.Name())) //nolint:gosec // the repository's snapshots
		if err != nil {
			return nil, err
		}
		have[name] = b
	}
	var diffs []SnapDiff
	for name, b := range want {
		old, ok := have[name]
		switch {
		case !ok:
			diffs = append(diffs, SnapDiff{name, "added"})
		case !bytes.Equal(old, b):
			diffs = append(diffs, SnapDiff{name, "changed"})
		}
	}
	for name := range have {
		if _, ok := want[name]; !ok {
			diffs = append(diffs, SnapDiff{name, "removed"})
		}
	}
	sort.Slice(diffs, func(i, j int) bool { return diffs[i].Tool < diffs[j].Tool })
	if update && len(diffs) > 0 {
		if err := os.MkdirAll(dir, 0o750); err != nil {
			return nil, err
		}
		for _, d := range diffs {
			p := filepath.Join(dir, d.Tool+".json")
			if d.Change == "removed" {
				if err := os.Remove(p); err != nil {
					return nil, err
				}
				continue
			}
			if err := os.WriteFile(p, want[d.Tool], 0o600); err != nil {
				return nil, err
			}
		}
	}
	return diffs, nil
}

// SnapError is the failure message for differences: which tools, and how to update (FR-1504).
func SnapError(kind string, diffs []SnapDiff) error {
	if len(diffs) == 0 {
		return nil
	}
	parts := make([]string, len(diffs))
	for i, d := range diffs {
		parts[i] = d.String()
	}
	return fmt.Errorf("what Claude sees of the %s tools differs from relay/e2e/toolsnaps/%s: %s. If the change is meant, update the snapshots in the same pull request (run the check with -update-snapshots, or take the files from this job's \"toolsnaps-%s\" artifact)",
		kind, kind, strings.Join(parts, ", "), kind)
}

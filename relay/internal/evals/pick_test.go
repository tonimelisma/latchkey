package evals

import (
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func repoMap(t *testing.T) *Map {
	t.Helper()
	m, err := LoadMap(filepath.Join("..", "..", "e2e", "capabilities.json"))
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestGlob(t *testing.T) {
	for _, c := range []struct {
		glob, path string
		want       bool
	}{
		{"macos/App/Files/**", "macos/App/Files/FilesTools.swift", true},
		{"macos/App/Files/**", "macos/App/FilesX.swift", false},
		{"macos/App/*", "macos/App/AppModel.swift", true},
		{"macos/App/*", "macos/App/Files/FilesTools.swift", false},
		{"relay/**", "relay/go.mod", true},
		{"relay/e2e/toolsnaps/mac/files_*", "relay/e2e/toolsnaps/mac/files_read.json", true},
		{"relay/e2e/toolsnaps/mac/files_*", "relay/e2e/toolsnaps/mac/shell_run.json", false},
		{"a/**/b.go", "a/b.go", true},
		{"a/**/b.go", "a/x/y/b.go", true},
	} {
		re, err := globRE(c.glob)
		if err != nil {
			t.Fatal(err)
		}
		if got := re.MatchString(c.path); got != c.want {
			t.Errorf("%s ~ %s = %v, want %v", c.glob, c.path, got, c.want)
		}
	}
}

func TestSelect(t *testing.T) {
	m := repoMap(t)

	none := m.Select([]string{"docs/STATUS.md", "README.md"})
	if none.Has("linux") || none.Has("mac") || len(none.Capabilities) != 0 {
		t.Fatalf("docs selected %+v", none)
	}

	files := m.Select([]string{"macos/App/Files/FilesTools.swift"})
	if !slices.Equal(files.Checks["mac"], []string{"core", "files"}) || files.Has("linux") {
		t.Fatalf("files change: %+v", files)
	}

	notes := m.Select([]string{"macos/App/Notes/NotesTools.swift"})
	if notes.Skipped["notes"] == "" || !slices.Equal(notes.Checks["mac"], []string{"core"}) {
		t.Fatalf("notes change: skipped with a reason, core still runs for the snapshots: %+v", notes)
	}

	core := m.Select([]string{"macos/App/AppModel.swift"})
	if !slices.Equal(core.Checks["mac"], []string{"browser", "core", "files", "shell"}) {
		t.Fatalf("app core selects every Mac capability: %+v", core)
	}

	shared := m.Select([]string{"relay/internal/mcpserver/mcpserver.go"})
	if !shared.Has("linux") || !shared.Has("mac") || len(shared.Capabilities) != len(m.Capabilities) {
		t.Fatalf("shared path selects all: %+v", shared)
	}

	snap := m.Select([]string{"relay/e2e/toolsnaps/mac/shell_run.json"})
	if !slices.Contains(snap.Checks["mac"], "shell") {
		t.Fatalf("a changed snapshot selects its capability: %+v", snap)
	}

	linux := m.Select([]string{"linux/internal/shell/shell.go"})
	if !slices.Equal(linux.Checks["linux"], []string{"linux", "relay"}) && !slices.Equal(linux.Checks["linux"], []string{"linux"}) {
		t.Fatalf("linux change: %+v", linux)
	}
}

// Every source file must fall under the map, so new code can't escape the per-PR checks.
func TestEverySourceFileIsMapped(t *testing.T) {
	m := repoMap(t)
	out, err := exec.CommandContext(t.Context(), "git", "-C", filepath.Join("..", "..", ".."), "ls-files", "macos/App", "macos/Shared", "linux", "relay/internal").Output()
	if err != nil {
		t.Skip("no git checkout:", err)
	}
	files := strings.Fields(string(out))
	if len(files) < 50 {
		t.Fatalf("only %d files listed", len(files))
	}
	if left := m.Unmatched(files); len(left) > 0 {
		t.Fatalf("files no capability in relay/e2e/capabilities.json covers: %v", left)
	}
}

func TestLoadMapRefusesBadEntries(t *testing.T) {
	dir := t.TempDir()
	for name, body := range map[string]string{
		"runner":  `{"capabilities":{"x":{"runner":"windows","checks":["a"],"paths":["a/**"]}}}`,
		"noskip":  `{"capabilities":{"x":{"runner":"mac","checks":[],"paths":["a/**"]}}}`,
		"selects": `{"capabilities":{"x":{"runner":"mac","checks":["a"],"paths":["a/**"],"selects":["y"]}}}`,
		"abs":     `{"capabilities":{"x":{"runner":"mac","checks":["a"],"paths":["/a"]}}}`,
	} {
		p := filepath.Join(dir, name+".json")
		writeFile(t, p, body)
		if _, err := LoadMap(p); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

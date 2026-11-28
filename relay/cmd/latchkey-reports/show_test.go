package main

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/tonimelisma/latchkey/relay/reports"
)

// Spec 014 FR-1452: a format 3 report becomes files the developer's agent can read, pictures as
// pictures; never inside a git repository (FR-1431).
func TestShowWritesTheReportAsFiles(t *testing.T) {
	jpeg := base64.StdEncoding.EncodeToString([]byte{0xff, 0xd8, 0xff, 1, 2})
	part, _ := json.Marshal(map[string]any{
		"log":   []any{map[string]any{"time": "t", "category": "browser", "text": "took cookies"}},
		"pages": []any{map[string]any{"name": "pk4m2", "source": "<html>cart</html>", "screenshot": map[string]any{"mimeType": "image/jpeg", "data": jpeg}}},
	})
	r := reports.Report{Format: 3, Summary: "checkout did nothing", Calls: []reports.Call{{
		Tool: "browser_look", Result: json.RawMessage(`[{"type":"text","text":"Cart"},{"type":"image","mimeType":"image/jpeg","data":"` + jpeg + `"}]`),
	}}, RelayLog: []string{"t WARN x"}, Parts: []reports.Part{{Machine: "machine 1", Answered: true, Part: part}, {Machine: "machine 2", Note: "offline"}}}
	plain, _ := json.Marshal(r)
	dir := t.TempDir()
	if err := writeReport(plain, dir); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{
		"report.json", "summary.json", "calls/001-browser_look.json", "calls/001-browser_look-2.jpg",
		"logs/relay.txt", "logs/machine-1.txt", "logs/machine-2.txt", "pages/machine-1-pk4m2.html.txt", "README.txt", "pages/machine-1-pk4m2.jpg",
	} {
		if _, err := os.Stat(filepath.Join(dir, f)); err != nil {
			t.Errorf("%s: %v", f, err)
		}
	}
	sum, _ := os.ReadFile(filepath.Join(dir, "summary.json"))
	if !strings.Contains(string(sum), `"calls": 1`) || !strings.Contains(string(sum), "machine 2: offline") {
		t.Errorf("summary: %s", sum)
	}

	repo := t.TempDir()
	if err := os.Mkdir(filepath.Join(repo, ".git"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(repo, "reports"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := writeReport(plain, filepath.Join(repo, "reports")); err == nil {
		t.Error("a folder inside a repository is refused")
	}
}

// The requirements this file's tests cite (docs/requirements/; script/process-check).
// Validates: FR-1431, FR-1452

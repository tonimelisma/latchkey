package evals

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func writeFile(t *testing.T, p, body string) {
	t.Helper()
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func tool(name, desc string) *mcp.Tool {
	return &mcp.Tool{Name: name, Description: desc, InputSchema: map[string]any{"type": "object", "properties": map[string]any{}}}
}

func TestSnapshots(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "mac")
	tools := []*mcp.Tool{tool("files_read", "Read a file."), tool("shell_run", "Run a command.")}

	diffs, err := CompareSnapshots(dir, tools, false)
	if err != nil || len(diffs) != 2 || diffs[0].Change != "added" {
		t.Fatalf("no snapshots yet: %v %v", diffs, err)
	}
	if _, err := CompareSnapshots(dir, tools, true); err != nil {
		t.Fatal(err)
	}
	if diffs, _ := CompareSnapshots(dir, tools, false); len(diffs) != 0 {
		t.Fatalf("after update: %v", diffs)
	}

	changed := []*mcp.Tool{tool("files_read", "Read a file, any kind."), tool("files_find", "Find files.")}
	diffs, _ = CompareSnapshots(dir, changed, false)
	got := []string{}
	for _, d := range diffs {
		got = append(got, d.String())
	}
	if strings.Join(got, ",") != "files_find added,files_read changed,shell_run removed" {
		t.Fatalf("diffs: %v", got)
	}
	err = SnapError("mac", diffs)
	if err == nil || !strings.Contains(err.Error(), "files_read changed") || !strings.Contains(err.Error(), "-update-snapshots") {
		t.Fatalf("error names the tools and the fix: %v", err)
	}
	if _, err := CompareSnapshots(dir, changed, true); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "shell_run.json")); !os.IsNotExist(err) {
		t.Fatal("a removed tool's snapshot stays")
	}
	if _, err := CompareSnapshots(dir, []*mcp.Tool{tool("../x", "")}, false); err == nil {
		t.Fatal("a tool name with a path was accepted")
	}
}

func TestSnapshotJSONIsCanonical(t *testing.T) {
	a, _ := SnapshotJSON(&mcp.Tool{Name: "x", InputSchema: map[string]any{"b": 1, "a": 2}})
	b, _ := SnapshotJSON(&mcp.Tool{Name: "x", InputSchema: map[string]any{"a": 2, "b": 1}})
	if string(a) != string(b) || !strings.HasSuffix(string(a), "\n") {
		t.Fatalf("%s vs %s", a, b)
	}
}

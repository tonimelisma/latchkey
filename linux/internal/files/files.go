// Package files is Files on a Linux server (spec 010 FR-1040 to FR-1044, plan D10): the same three
// tools as the Mac's (files_find, files_read, files_change), with the server's own rules: search
// walks the disk instead of asking Spotlight, and delete removes for good (Toni, 2026-10-31).
package files

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/tonimelisma/latchkey/linux/internal/config"
	"github.com/tonimelisma/latchkey/linux/internal/tools"
)

// Files holds what the tools need.
type Files struct {
	Home string
	Own  []string // Latchkey's own files and folders (FR-1043)
	// SearchTime bounds a search (the relay's deadline for files_find is 30 s).
	SearchTime time.Duration
}

// New makes the tools' state from the program's paths.
func New(p config.Paths) *Files {
	return &Files{Home: p.Home, Own: p.Own(), SearchTime: 20 * time.Second}
}

// Tools are the Files tools at a level: read for FilesRead, read and change for FilesWrite.
func (f *Files) Tools(level string) []tools.Tool {
	var out []tools.Tool
	if level == config.FilesRead || level == config.FilesWrite {
		out = append(out, f.findTool(), f.readTool())
	}
	if level == config.FilesWrite {
		out = append(out, f.changeTool())
	}
	return out
}

// resolve makes a path absolute: "" and "~" are the home folder, "~/x" and relative paths are
// taken from it.
func (f *Files) resolve(p string) string {
	p = strings.TrimSpace(p)
	switch {
	case p == "" || p == "~":
		return f.Home
	case strings.HasPrefix(p, "~/"):
		return filepath.Join(f.Home, p[2:])
	case !filepath.IsAbs(p):
		return filepath.Join(f.Home, p)
	}
	return filepath.Clean(p)
}

// --- files_find ---

func (f *Files) findTool() tools.Tool {
	return tools.Tool{
		Def: tools.Make(tools.Spec{
			Name: "files_find", Title: "Find Files",
			Description: "Finds files on the server. With query: searches names and the text of files for it, newest first (inside path, if given), " +
				"within 20 seconds; hidden folders, /proc, /sys, and /dev are skipped unless path is inside them. Without query: lists the folder at " +
				"path (the home folder if empty), or shows a file's details. Paths may start with ~; others are taken from the home folder.",
			Input: map[string]any{
				"query":  tools.String("Words in the file's name or text"),
				"path":   tools.String("The folder to list or search in, or a file to describe"),
				"hidden": tools.Bool("When listing: include hidden files"),
				"limit":  tools.Integer("When searching: at most this many files (default 30, up to 200)"),
			},
			ReadOnly: true, DeadlineMS: 30_000,
		}),
		Run: f.find,
	}
}

func (f *Files) find(ctx context.Context, a tools.Args) tools.Result {
	query, err := a.String("query")
	if err != nil {
		return tools.Failf("%v", err)
	}
	p, err := a.String("path")
	if err != nil {
		return tools.Failf("%v", err)
	}
	path := f.resolve(p)
	info, err := os.Stat(path)
	if err != nil {
		return tools.Failf("%s", describeErr(path, err))
	}
	if strings.TrimSpace(query) != "" {
		limit, err := a.Int("limit", 30, 1, 200)
		if err != nil {
			return tools.Failf("%v", err)
		}
		return f.search(ctx, path, strings.TrimSpace(query), limit)
	}
	if !info.IsDir() {
		return tools.Text(details(path, info))
	}
	hidden, err := a.Bool("hidden", false)
	if err != nil {
		return tools.Failf("%v", err)
	}
	return listFolder(path, hidden)
}

func details(path string, info fs.FileInfo) string {
	kind := "file"
	switch {
	case info.IsDir():
		kind = "folder"
	case info.Mode()&fs.ModeSymlink != 0:
		kind = "link"
	}
	return fmt.Sprintf("%s\nKind: %s\nSize: %s\nModified: %s\nPermissions: %s",
		path, kind, size(info.Size()), info.ModTime().Format("2006-01-02 15:04:05 MST"), info.Mode().String())
}

const maxListed = 500

func listFolder(path string, hidden bool) tools.Result {
	entries, err := os.ReadDir(path)
	if err != nil {
		return tools.Failf("%s", describeErr(path, err))
	}
	var b strings.Builder
	shown := 0
	for _, e := range entries {
		if !hidden && strings.HasPrefix(e.Name(), ".") {
			continue
		}
		if shown == maxListed {
			fmt.Fprintf(&b, "(Only the first %d are shown.)\n", maxListed)
			break
		}
		shown++
		info, err := e.Info()
		switch {
		case err != nil:
			fmt.Fprintf(&b, "%s\n", e.Name())
		case e.IsDir():
			fmt.Fprintf(&b, "%s/\n", e.Name())
		default:
			fmt.Fprintf(&b, "%s  (%s, %s)\n", e.Name(), size(info.Size()), info.ModTime().Format("2006-01-02 15:04"))
		}
	}
	if shown == 0 {
		return tools.Text(path + " is empty" + map[bool]string{true: ".", false: " (hidden files aside; pass hidden to see them)."}[hidden])
	}
	return tools.Text(fmt.Sprintf("%s:\n%s", path, b.String()))
}

// skipped are system folders a search never walks into unless it starts inside them.
var skipped = []string{"/proc", "/sys", "/dev", "/run"}

type hit struct {
	path string
	mod  time.Time
	size int64
	how  string // "name" or "text"
}

// search walks path for names and texts containing query, case aside, until limit × 5 hits or
// the time is up, then shows the newest limit.
func (f *Files) search(ctx context.Context, root, query string, limit int) tools.Result {
	ctx, cancel := context.WithTimeout(ctx, f.SearchTime)
	defer cancel()
	needle := strings.ToLower(query)
	var hits []hit
	stopped := ""
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if ctx.Err() != nil {
			stopped = "time"
			return fs.SkipAll
		}
		if err != nil {
			return nil // unreadable: skip
		}
		if d.IsDir() && path != root {
			if strings.HasPrefix(d.Name(), ".") || slices.Contains(skipped, path) {
				return fs.SkipDir
			}
		}
		if path == root && d.IsDir() {
			return nil
		}
		how := ""
		if strings.Contains(strings.ToLower(d.Name()), needle) {
			how = "name"
		} else if d.Type().IsRegular() && containsText(path, needle) {
			how = "text"
		}
		if how == "" {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		hits = append(hits, hit{path, info.ModTime(), info.Size(), how})
		if len(hits) >= limit*5 {
			stopped = "count"
			return fs.SkipAll
		}
		return nil
	})
	if err != nil {
		return tools.Failf("%s", describeErr(root, err))
	}
	slices.SortFunc(hits, func(a, b hit) int { return b.mod.Compare(a.mod) })
	var b strings.Builder
	if len(hits) == 0 {
		fmt.Fprintf(&b, "No file under %s has %q in its name or text.", root, query)
	} else {
		fmt.Fprintf(&b, "Files under %s with %q, newest first:\n", root, query)
		for i, h := range hits {
			if i == limit {
				break
			}
			fmt.Fprintf(&b, "%s  (%s, %s, matched its %s)\n", h.path, size(h.size), h.mod.Format("2006-01-02 15:04"), h.how)
		}
	}
	switch stopped {
	case "time":
		fmt.Fprintf(&b, "\n(The search stopped after %s; search a smaller folder with path to see more.)", f.SearchTime)
	case "count":
		b.WriteString("\n(Many more files match; narrow the query or the folder.)")
	}
	return tools.Text(strings.TrimRight(b.String(), "\n"))
}

// containsText reports whether a small text file contains the (lower-case) needle.
func containsText(path, needle string) bool {
	info, err := os.Stat(path)
	if err != nil || info.Size() > 2<<20 || info.Size() == 0 {
		return false
	}
	data, err := os.ReadFile(path) //nolint:gosec // search reads the files it walks, by design (FR-1040)
	if err != nil || isBinary(data) {
		return false
	}
	return strings.Contains(strings.ToLower(string(data)), needle)
}

func size(n int64) string {
	switch {
	case n < 1024:
		return fmt.Sprintf("%d bytes", n)
	case n < 1024*1024:
		return fmt.Sprintf("%.1f KB", float64(n)/1024)
	case n < 1024*1024*1024:
		return fmt.Sprintf("%.1f MB", float64(n)/(1024*1024))
	}
	return fmt.Sprintf("%.1f GB", float64(n)/(1024*1024*1024))
}

// describeErr turns a file error into a sentence.
func describeErr(path string, err error) string {
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return path + " doesn't exist."
	case errors.Is(err, fs.ErrPermission):
		return path + " can't be opened: this account has no permission (Files never uses sudo; Shell can, where allowed)."
	}
	return fmt.Sprintf("%s: %v", path, err)
}

package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"

	"github.com/tonimelisma/latchkey/relay/internal/evals"
)

// pickCmd prints what the changed files select and, on GitHub, writes the job outputs
// linux, mac (true/false) and linux_checks, mac_checks (comma-separated) (FR-1500, FR-1502).
func pickCmd(args []string) error {
	fs := flag.NewFlagSet("pick", flag.ContinueOnError)
	base := fs.String("base", "", "git ref to compare with (the pull request's base); empty: select everything")
	mapPath := fs.String("map", "e2e/capabilities.json", "the path map")
	files := fs.String("files", "", "comma-separated changed files instead of git (for a try)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	m, err := evals.LoadMap(*mapPath)
	if err != nil {
		return err
	}
	var changed []string
	switch {
	case *files != "":
		changed = strings.Split(*files, ",")
	case *base != "":
		top, err := exec.CommandContext(context.Background(), "git", "rev-parse", "--show-toplevel").Output()
		if err != nil {
			return fmt.Errorf("git: %w", err)
		}
		out, err := exec.CommandContext(context.Background(), "git", "-C", strings.TrimSpace(string(top)), //nolint:gosec // a ref from the workflow, passed as one argument
			"diff", "--name-only", *base+"...HEAD").Output()
		if err != nil {
			return fmt.Errorf("git diff %s...HEAD: %w", *base, err)
		}
		changed = strings.Fields(string(out))
	default:
		changed = []string{"relay/e2e/capabilities.json"} // a shared path: everything (pushes to main)
	}
	sel := m.Select(changed)
	fmt.Printf("changed files: %d\ncapabilities: %s\n", len(changed), strings.Join(sel.Capabilities, ", "))
	for _, r := range []string{"linux", "mac"} {
		fmt.Printf("%s checks: %s\n", r, orNone(sel.Checks[r]))
	}
	names := make([]string, 0, len(sel.Skipped))
	for n := range sel.Skipped {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		fmt.Printf("skipped on GitHub, weekly run only: %s (%s)\n", n, sel.Skipped[n])
	}
	if out := os.Getenv("GITHUB_OUTPUT"); out != "" {
		f, err := os.OpenFile(out, os.O_APPEND|os.O_WRONLY, 0) //nolint:gosec // GitHub's own output file
		if err != nil {
			return err
		}
		defer func() { _ = f.Close() }()
		_, err = fmt.Fprintf(f, "linux=%t\nmac=%t\nlinux_checks=%s\nmac_checks=%s\n",
			sel.Has("linux"), sel.Has("mac"), strings.Join(sel.Checks["linux"], ","), strings.Join(sel.Checks["mac"], ","))
		return err
	}
	return nil
}

func orNone(s []string) string {
	if len(s) == 0 {
		return "none"
	}
	return strings.Join(s, ", ")
}

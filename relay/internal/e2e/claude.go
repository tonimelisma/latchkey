package e2e

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
)

// AskClaude runs real Claude Code once, non-interactively, with only the MCP servers in cfg and only
// tool allowed, and returns its answer.
func AskClaude(ctx context.Context, model, cfg, tool, prompt string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "claude", "-p", prompt, //nolint:gosec // fixed program; arguments are ours
		"--model", model, "--mcp-config", cfg, "--strict-mcp-config",
		"--allowedTools", tool, "--output-format", "text",
		"--setting-sources", "user") // never project or local settings (hooks) from the directory
	// A fresh, empty directory in the user's own cache directory: Claude Code loads CLAUDE.md from
	// its working directory and every directory above it, so neither may be anywhere another local
	// user can write, such as the shared temp directory.
	cache, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(cache, 0o700); err != nil {
		return "", err
	}
	if err := privateAncestry(cache); err != nil {
		return "", fmt.Errorf("no private place to run Claude Code: %w", err)
	}
	work, err := os.MkdirTemp(cache, "latchkey-check-") // mode 0700
	if err != nil {
		return "", err
	}
	defer func() { _ = os.RemoveAll(work) }()
	cmd.Dir = work
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("claude: %w: %s", err, out)
	}
	return string(out), nil
}

// privateAncestry checks that dir and every directory above it belong to this user or root and
// that nobody else can write them, so no other local user can plant a CLAUDE.md or .claude
// folder where Claude Code looks.
func privateAncestry(dir string) error {
	dir, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return err
	}
	uid := uint32(os.Getuid()) //nolint:gosec // uids are small non-negative numbers
	for d := dir; ; d = filepath.Dir(d) {
		fi, err := os.Stat(d)
		if err != nil {
			return err
		}
		st, ok := fi.Sys().(*syscall.Stat_t)
		if !ok {
			return fmt.Errorf("%s: no owner information", d)
		}
		if st.Uid != uid && st.Uid != 0 {
			return fmt.Errorf("%s belongs to another user", d)
		}
		if fi.Mode().Perm()&0o022 != 0 {
			return fmt.Errorf("%s can be written by other users", d)
		}
		if d == filepath.Dir(d) {
			return nil
		}
	}
}

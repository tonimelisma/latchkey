package e2e

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Claude Code loads project settings, hooks, and CLAUDE.md from its working directory and the
// CLAUDE.md files of every directory above it, so the check must run it in a fresh directory
// whose every parent only the user (or root) can write, never under the shared temp directory.
func TestAskClaudeRunsInAFreshPrivateDirectory(t *testing.T) {
	bin := t.TempDir()
	fake := filepath.Join(bin, "claude")
	script := "#!/bin/sh\npwd -P\necho \"$@\"\n"
	require.NoError(t, os.WriteFile(fake, []byte(script), 0o700)) //nolint:gosec // test script
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))

	out, err := AskClaude(t.Context(), "m", "cfg.json", "tool", "prompt")
	require.NoError(t, err)
	lines := strings.Split(strings.TrimSpace(out), "\n")
	require.Len(t, lines, 2)
	wd, args := lines[0], lines[1]

	shared, err := filepath.EvalSymlinks(os.TempDir())
	require.NoError(t, err)
	assert.False(t, strings.HasPrefix(wd, filepath.Clean(shared)), "not under the shared temp directory: %s", wd)
	require.NoError(t, privateAncestry(filepath.Dir(wd)), "no other user can plant files above it")
	_, err = os.Stat(wd)
	assert.True(t, os.IsNotExist(err), "the directory is removed afterwards")
	assert.Contains(t, args, "--setting-sources user", "project and local settings are not read")
}

// A directory below one that others can write (like /tmp) is refused, whoever owns it.
func TestPrivateAncestryRefusesSharedParents(t *testing.T) {
	shared := filepath.Join(t.TempDir(), "shared")
	require.NoError(t, os.Mkdir(shared, 0o700))
	require.NoError(t, os.Chmod(shared, 0o1777)) //nolint:gosec // simulating /tmp
	inner := filepath.Join(shared, "mine")
	require.NoError(t, os.Mkdir(inner, 0o700))
	require.Error(t, privateAncestry(inner))
	require.Error(t, privateAncestry("/tmp"))

	home, err := os.UserHomeDir()
	require.NoError(t, err)
	require.NoError(t, privateAncestry(home))
}

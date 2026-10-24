package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Claude Code loads project settings, hooks, and CLAUDE.md from its working directory, so the
// check must not run it in the shared temp directory, where another local user could plant them.
func TestAskClaudeRunsInAFreshPrivateDirectory(t *testing.T) {
	bin := t.TempDir()
	fake := filepath.Join(bin, "claude")
	require.NoError(t, os.WriteFile(fake, []byte("#!/bin/sh\npwd -P\n"), 0o700)) //nolint:gosec // test script
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))

	out, err := askClaude(t.Context(), "m", "cfg.json", "tool", "prompt")
	require.NoError(t, err)
	wd := strings.TrimSpace(out)

	shared, err := filepath.EvalSymlinks(os.TempDir())
	require.NoError(t, err)
	assert.NotEqual(t, filepath.Clean(shared), wd, "not the shared temp directory")
	_, err = os.Stat(wd)
	assert.True(t, os.IsNotExist(err), "the directory is removed afterwards")
}

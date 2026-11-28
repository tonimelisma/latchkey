package setup_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/linux/internal/config"
	"github.com/tonimelisma/latchkey/linux/internal/setup"
)

// Uninstalling removes the activity log, the daily files and the old single file alike (FR-1027;
// trace-files.md: uninstalling is one of the only removals).
func TestUninstallRemovesTheActivityLog(t *testing.T) {
	home := t.TempDir()
	p := config.PathsFor(home, "", "", "")
	assert.Equal(t, filepath.Join(p.Data, "activity"), p.Activity)
	assert.Equal(t, filepath.Join(p.Data, "activity.jsonl"), p.ActivityV0)
	require.NoError(t, os.MkdirAll(p.Activity, 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(p.Activity, "2026-11-15.jsonl"), []byte("{}\n"), 0o600))
	require.NoError(t, os.WriteFile(p.ActivityV0, []byte("{}\n"), 0o600))
	require.NoError(t, setup.RemoveFiles(p))
	_, err := os.Stat(p.Data)
	assert.ErrorIs(t, err, os.ErrNotExist)
}

// The requirements this file's tests cite (docs/requirements/; script/process-check).
// Validates: FR-1027

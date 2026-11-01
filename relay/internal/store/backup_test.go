package store_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

func backups(t *testing.T, dir string) []string {
	t.Helper()
	names, err := filepath.Glob(filepath.Join(dir, "backups", "relay-*.db"))
	require.NoError(t, err)
	return names
}

// A copy of the database is kept before an update changes its layout (spec 009 FR-909, plan D4).
func TestCopyBeforeMigrating(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	path := filepath.Join(dir, "relay.db")

	s, err := store.Open(ctx, path)
	require.NoError(t, err)
	require.NoError(t, s.Close())
	assert.Empty(t, backups(t, dir), "a new database has nothing to keep")

	older := filepath.Join(t.TempDir(), "relay.db")
	require.NoError(t, store.MigrateTo(ctx, older, 11))
	s, err = store.Open(ctx, older)
	require.NoError(t, err)
	assert.NotEmpty(t, s.MigrationBackup(), "reported, for the log")
	require.NoError(t, s.Close())
	kept := backups(t, filepath.Dir(older))
	require.Len(t, kept, 1)
	assert.Contains(t, filepath.Base(kept[0]), "-v11.db", "named after the version it was")

	copied, err := store.Open(ctx, kept[0]) // the copy is a working database of that version
	require.NoError(t, err)
	require.NoError(t, copied.Close())

	s, err = store.Open(ctx, older)
	require.NoError(t, err)
	assert.Empty(t, s.MigrationBackup())
	require.NoError(t, s.Close())
	assert.Len(t, backups(t, filepath.Dir(older)), 1, "nothing pending, no new copy")
}

func TestThreeCopiesKept(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "backups"), 0o700))
	for _, name := range []string{"relay-20260101T000000Z-v7.db", "relay-20260201T000000Z-v8.db", "relay-20260301T000000Z-v9.db"} {
		require.NoError(t, os.WriteFile(filepath.Join(dir, "backups", name), []byte("old"), 0o600))
	}
	path := filepath.Join(dir, "relay.db")
	require.NoError(t, store.MigrateTo(ctx, path, 11))
	s, err := store.Open(ctx, path)
	require.NoError(t, err)
	require.NoError(t, s.Close())
	kept := backups(t, dir)
	require.Len(t, kept, 3)
	assert.NotContains(t, kept, filepath.Join(dir, "backups", "relay-20260101T000000Z-v7.db"), "the oldest goes")
}

package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// `relay reset-keys` does nothing without --confirm, and with it lets a relay whose key file is
// lost start again (FR-189).
func TestResetKeysCommand(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	db, keyFile := filepath.Join(dir, "relay.db"), filepath.Join(dir, "relay.key")
	getenv := func(k string) string { return map[string]string{"DATA_DIR": dir}[k] }
	s, err := store.Open(ctx, db)
	require.NoError(t, err)
	_, err = s.KeyOrCreate(ctx, "oauth_hmac", func() ([]byte, error) { return []byte("0123456789abcdef0123456789abcdef"), nil })
	require.NoError(t, err)
	require.NoError(t, s.Close())
	require.NoError(t, os.Remove(keyFile))
	_, err = store.Open(ctx, db)
	require.ErrorIs(t, err, store.ErrKeys, "the relay refuses to start")

	var out, errOut bytes.Buffer
	for _, args := range [][]string{nil, {"--yes"}, {"--confirm", "extra"}} {
		errOut.Reset()
		assert.Equal(t, 2, resetKeys(args, getenv, &out, &errOut), args)
		assert.Contains(t, errOut.String(), "usage: relay reset-keys --confirm")
		assert.Contains(t, errOut.String(), "Everyone is signed out")
	}
	_, err = store.Open(ctx, db)
	require.ErrorIs(t, err, store.ErrKeys, "nothing was deleted without --confirm")

	assert.Equal(t, 1, resetKeys([]string{"--confirm"}, func(string) string { return filepath.Join(dir, "elsewhere") }, &out, &errOut), "no database there")
	assert.NoFileExists(t, filepath.Join(dir, "elsewhere", "relay.db"), "and none is made")

	require.Equal(t, 0, resetKeys([]string{"--confirm"}, getenv, &out, &errOut), errOut.String())
	assert.Contains(t, out.String(), "The stored keys are deleted.")
	s, err = store.Open(ctx, db)
	require.NoError(t, err, "the relay starts again")
	require.NoError(t, s.Close())
}

package config_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/linux/internal/config"
)

func TestPathsFollowXDG(t *testing.T) {
	p := config.PathsFor("/home/toni", "", "", "")
	assert.Equal(t, "/home/toni/.config/latchkey/settings.json", p.Settings)
	assert.Equal(t, "/home/toni/.local/share/latchkey/device.key", p.Key)
	assert.Equal(t, "/home/toni/.cache/latchkey/jobs", p.Jobs)
	assert.Equal(t, "/home/toni/.local/lib/latchkey", p.Program)

	p = config.PathsFor("/home/toni", "/x/config", "relative", "/x/cache")
	assert.Equal(t, "/x/config/latchkey", p.Config)
	assert.Equal(t, "/home/toni/.local/share/latchkey", p.Data, "a relative XDG path is ignored, as the spec says")
	assert.Equal(t, "/x/cache/latchkey", p.Cache)
	assert.Contains(t, p.Own(), config.ServiceFile)
}

func TestSettingsRoundTrip(t *testing.T) {
	home := t.TempDir()
	p := config.PathsFor(home, "", "", "")
	_, err := config.Load(p)
	require.ErrorIs(t, err, os.ErrNotExist)

	s := config.Defaults()
	assert.Equal(t, config.On, s.Shell, "a new server starts with Shell on (FR-1024)")
	assert.Equal(t, config.FilesWrite, s.Files, "and Files read and write")
	s.Relay, s.DeviceID, s.Name = "https://relay.example", "dev_1", "homeserver"
	require.NoError(t, config.Save(p, s))
	info, err := os.Stat(p.Settings)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm(), "only the Owner reads it")

	got, err := config.Load(p)
	require.NoError(t, err)
	assert.Equal(t, s, got)
	assert.Equal(t, "homeserver", got.MachineName())
	assert.Equal(t, config.DefaultUpdateRepo, got.Repo())
	assert.True(t, got.AutoUpdates())

	s.Shell = "maybe"
	require.Error(t, config.Save(p, s))
	require.NoError(t, os.WriteFile(p.Settings, []byte(`{"shell":"on","files":"everything"}`), 0o600))
	_, err = config.Load(p)
	require.ErrorContains(t, err, "files must be")
	entries, _ := os.ReadDir(filepath.Dir(p.Settings))
	assert.Len(t, entries, 1, "no temporary files left")
}

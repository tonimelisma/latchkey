// Package config holds the Linux program's settings and where its files live (spec 010 plan D8,
// contracts/server-program.md). Settings change only on the server, by the Owner's command or
// by editing the file; the relay has no way to change them (FR-1024).
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Levels.
const (
	On  = "on"
	Off = "off"

	FilesOff   = "off"
	FilesRead  = "read"
	FilesWrite = "write"
)

// DefaultUpdateRepo is where releases come from unless settings name another (a fork's).
const DefaultUpdateRepo = "tonimelisma/latchkey"

// Settings is settings.json.
type Settings struct {
	Relay    string `json:"relay"`               // https://relay.example
	DeviceID string `json:"device_id,omitempty"` // empty until paired
	Name     string `json:"name,omitempty"`      // the name shown to Claude; empty: the hostname
	Shell    string `json:"shell"`               // On or Off
	Files    string `json:"files"`               // FilesOff, FilesRead, FilesWrite
	Paused   bool   `json:"paused,omitempty"`    // every call answered "paused" (FR-1025)
	// UpdateRepo is the GitHub repository whose server-v* releases the program updates from.
	UpdateRepo string `json:"update_repo,omitempty"`
	// AutoUpdate turns the daily update off when false.
	AutoUpdate *bool `json:"auto_update,omitempty"`
}

// Defaults are a newly paired server's settings: Shell On, Files Read & write, as the Mac (Toni,
// 2026-10-31, FR-1024).
func Defaults() Settings {
	return Settings{Shell: On, Files: FilesWrite}
}

// Repo is the repository updates come from.
func (s Settings) Repo() string {
	if s.UpdateRepo != "" {
		return s.UpdateRepo
	}
	return DefaultUpdateRepo
}

// AutoUpdates reports whether the daily update runs.
func (s Settings) AutoUpdates() bool { return s.AutoUpdate == nil || *s.AutoUpdate }

// MachineName is the name shown to Claude: the settings' name or the hostname.
func (s Settings) MachineName() string {
	if n := strings.TrimSpace(s.Name); n != "" {
		return n
	}
	if h, err := os.Hostname(); err == nil && h != "" {
		return h
	}
	return "Linux server"
}

// Validate checks the levels.
func (s Settings) Validate() error {
	if s.Shell != On && s.Shell != Off {
		return fmt.Errorf("shell must be %q or %q, not %q", On, Off, s.Shell)
	}
	switch s.Files {
	case FilesOff, FilesRead, FilesWrite:
	default:
		return fmt.Errorf("files must be %q, %q, or %q, not %q", FilesOff, FilesRead, FilesWrite, s.Files)
	}
	return nil
}

// Paths are where the program's files live, all inside the Owner's home folder except the
// service file.
type Paths struct {
	Home     string
	Config   string // ~/.config/latchkey
	Data     string // ~/.local/share/latchkey
	Cache    string // ~/.cache/latchkey
	Program  string // ~/.local/lib/latchkey (the program and its previous version)
	Service  string // /etc/systemd/system/latchkey.service
	Settings string // Config/settings.json
	Key      string // Data/device.key
	Activity string // Data/activity.jsonl
	Update   string // Data/update.json
	Jobs     string // Cache/jobs: each command's scratch folder
	Bin      string // Cache/bin: the sudo wrapper, first on every command's PATH
	Command  string // ~/.local/bin/latchkey: a link to the program, for the Owner's shell
}

// ServiceFile is the systemd unit's path.
const ServiceFile = "/etc/systemd/system/latchkey.service"

// DefaultPaths follows the XDG base directories for home.
func DefaultPaths() (Paths, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return Paths{}, err
	}
	return PathsFor(home, os.Getenv("XDG_CONFIG_HOME"), os.Getenv("XDG_DATA_HOME"), os.Getenv("XDG_CACHE_HOME")), nil
}

// PathsFor builds the paths from a home folder and the XDG variables (empty: the defaults).
func PathsFor(home, xdgConfig, xdgData, xdgCache string) Paths {
	or := func(v, def string) string {
		if v != "" && filepath.IsAbs(v) {
			return v
		}
		return def
	}
	p := Paths{
		Home:    home,
		Config:  filepath.Join(or(xdgConfig, filepath.Join(home, ".config")), "latchkey"),
		Data:    filepath.Join(or(xdgData, filepath.Join(home, ".local", "share")), "latchkey"),
		Cache:   filepath.Join(or(xdgCache, filepath.Join(home, ".cache")), "latchkey"),
		Program: filepath.Join(home, ".local", "lib", "latchkey"),
		Service: ServiceFile,
	}
	p.Settings = filepath.Join(p.Config, "settings.json")
	p.Key = filepath.Join(p.Data, "device.key")
	p.Activity = filepath.Join(p.Data, "activity.jsonl")
	p.Update = filepath.Join(p.Data, "update.json")
	p.Jobs = filepath.Join(p.Cache, "jobs")
	p.Bin = filepath.Join(p.Cache, "bin")
	p.Command = filepath.Join(home, ".local", "bin", "latchkey")
	return p
}

// Own are Latchkey's own files and folders: readable by Files, never changed by it (FR-1043).
func (p Paths) Own() []string {
	return []string{p.Config, p.Data, p.Program, p.Bin, p.Service}
}

// Load reads the settings. A missing file is os.ErrNotExist.
func Load(p Paths) (Settings, error) {
	data, err := os.ReadFile(p.Settings)
	if err != nil {
		return Settings{}, err
	}
	s := Defaults()
	if err := json.Unmarshal(data, &s); err != nil {
		return Settings{}, fmt.Errorf("%s: %w", p.Settings, err)
	}
	if err := s.Validate(); err != nil {
		return Settings{}, fmt.Errorf("%s: %w", p.Settings, err)
	}
	return s, nil
}

// Save writes the settings atomically, readable only by the Owner.
func Save(p Paths, s Settings) error {
	if err := s.Validate(); err != nil {
		return err
	}
	if err := os.MkdirAll(p.Config, 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return WriteAtomic(p.Settings, append(data, '\n'), 0o600)
}

// WriteAtomic writes a file through a temporary file in the same folder and a rename.
func WriteAtomic(path string, data []byte, mode os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	_, err = tmp.Write(data)
	err = errors.Join(err, tmp.Chmod(mode), tmp.Close())
	if err == nil {
		err = os.Rename(name, path)
	}
	if err != nil {
		_ = os.Remove(name)
	}
	return err
}

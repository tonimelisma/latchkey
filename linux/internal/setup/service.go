package setup

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/tonimelisma/latchkey/linux/internal/config"
)

// Unit is the systemd service (plan D8): the Owner's own account, its own control group subtree
// (Delegate=yes, for stopping what commands leave running), started at boot and restarted when
// it exits (an update exits to be restarted). Stopping it stops everything in its group.
func Unit(p config.Paths, u *user.User) string {
	return strings.Join([]string{
		"[Unit]",
		"Description=Latchkey: Claude's access to this server",
		"Documentation=https://github.com/tonimelisma/latchkey",
		"Wants=network-online.target",
		"After=network-online.target",
		"",
		"[Service]",
		"Type=simple",
		"User=" + u.Username,
		"Environment=HOME=" + u.HomeDir,
		"ExecStart=" + filepath.Join(p.Program, "latchkey") + " run",
		"Restart=always",
		"RestartSec=5",
		"Delegate=yes",
		"TimeoutStopSec=20",
		"",
		"[Install]",
		"WantedBy=multi-user.target",
		"",
	}, "\n")
}

// Check says whether this system can run Latchkey (FR-1020): Linux, 64-bit, systemd, and cgroup v2.
func Check() error {
	if runtime.GOOS != "linux" {
		return errors.New("the server program runs on Linux only")
	}
	if _, err := os.Stat("/run/systemd/system"); err != nil {
		return errors.New("this system doesn't run systemd, which Latchkey needs to start at boot")
	}
	if _, err := os.Stat("/sys/fs/cgroup/cgroup.controllers"); err != nil {
		return errors.New("this system has no cgroup v2, which Latchkey needs to stop what commands leave running (Ubuntu 22.04 and Debian 11 or newer have it)")
	}
	return nil
}

// Runner runs a command, with the terminal attached, so sudo can ask the Owner for a password.
type Runner func(name string, args ...string) error

// Terminal runs commands attached to the Owner's terminal.
func Terminal(name string, args ...string) error {
	cmd := exec.CommandContext(context.Background(), name, args...) //nolint:gosec // fixed commands (sudo, systemctl) from InstallService and RemoveService
	if tty, err := os.Open("/dev/tty"); err == nil {                // install.sh is piped into sh: stdin isn't the terminal
		defer func() { _ = tty.Close() }()
		cmd.Stdin = tty
	} else {
		cmd.Stdin = os.Stdin
	}
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	return cmd.Run()
}

// InstallProgram copies the running program to its place in the home folder (so it can update
// itself) unless it already runs from there.
func InstallProgram(p config.Paths) (string, error) {
	self, err := os.Executable()
	if err != nil {
		return "", err
	}
	dest := filepath.Join(p.Program, "latchkey")
	if real, err := filepath.EvalSymlinks(self); err != nil || real != dest {
		if err := os.MkdirAll(p.Program, 0o755); err != nil { //nolint:gosec // the program's folder; the program must be runnable
			return "", err
		}
		src, err := os.Open(self) //nolint:gosec // the running program itself
		if err != nil {
			return "", err
		}
		defer func() { _ = src.Close() }()
		data, err := io.ReadAll(src)
		if err != nil {
			return "", err
		}
		if err := config.WriteAtomic(dest, data, 0o755); err != nil {
			return "", err
		}
	}
	return dest, linkCommand(p, dest)
}

// linkCommand puts `latchkey` in ~/.local/bin, which Debian's and Ubuntu's login shells put on the
// PATH; a link already there to something else is left alone.
func linkCommand(p config.Paths, dest string) error {
	link := p.Command
	if target, err := os.Readlink(link); err == nil {
		if target == dest {
			return nil
		}
		return nil // someone else's latchkey: not ours to replace
	}
	if _, err := os.Lstat(link); err == nil {
		return nil // a file of the Owner's own
	}
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil { //nolint:gosec // ~/.local/bin, the usual mode
		return err
	}
	return os.Symlink(dest, link)
}

// InstallService writes the unit with sudo and starts it (asking for the Owner's password once
// if sudo needs it; Latchkey never edits sudo's settings).
func InstallService(p config.Paths, run Runner) error {
	u, err := user.Current()
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp("", "latchkey-*.service")
	if err != nil {
		return err
	}
	defer func() { _ = os.Remove(tmp.Name()) }()
	if _, err := tmp.WriteString(Unit(p, u)); err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	steps := [][]string{
		{"sudo", "install", "-m", "644", "-o", "root", "-g", "root", tmp.Name(), p.Service},
		{"sudo", "systemctl", "daemon-reload"},
		{"sudo", "systemctl", "enable", "latchkey"},
		{"sudo", "systemctl", "restart", "latchkey"},
	}
	for _, s := range steps {
		if err := run(s[0], s[1:]...); err != nil {
			return fmt.Errorf("%s: %w", strings.Join(s, " "), err)
		}
	}
	return nil
}

// RemoveService stops and removes the unit with sudo.
func RemoveService(p config.Paths, run Runner) error {
	var errs []error
	for _, s := range [][]string{
		{"sudo", "systemctl", "disable", "--now", "latchkey"},
		{"sudo", "rm", "-f", p.Service},
		{"sudo", "systemctl", "daemon-reload"},
	} {
		if err := run(s[0], s[1:]...); err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", strings.Join(s, " "), err))
		}
	}
	return errors.Join(errs...)
}

// RemoveFiles deletes the program, settings, data, and cache (FR-1027).
func RemoveFiles(p config.Paths) error {
	var errs []error
	for _, dir := range []string{p.Config, p.Data, p.Cache, p.Program} {
		if err := os.RemoveAll(dir); err != nil {
			errs = append(errs, err)
		}
	}
	if target, err := os.Readlink(p.Command); err == nil && target == filepath.Join(p.Program, "latchkey") {
		errs = append(errs, os.Remove(p.Command)) // only our own link
	}
	return errors.Join(errs...)
}

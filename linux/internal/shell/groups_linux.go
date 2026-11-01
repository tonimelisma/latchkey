//go:build linux

package shell

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Groups follows each command in its own control group (cgroup v2) under the service's own,
// which systemd delegates to it (Delegate=yes, plan D9). Everything a command starts stays in
// its group, sudo included on Debian and Ubuntu, and the kernel's cgroup.kill stops all of it
// whatever user it runs as.
type Groups struct {
	root string // the service's own group, e.g. /sys/fs/cgroup/system.slice/latchkey.service
}

const cgroupFS = "/sys/fs/cgroup"

// OpenGroups moves the program into <own>/service and prepares <own>/jobs. It fails where
// there is no cgroup v2 or the group isn't the program's to change (run outside the service).
func OpenGroups() (*Groups, error) {
	data, err := os.ReadFile("/proc/self/cgroup")
	if err != nil {
		return nil, err
	}
	var own string
	for line := range strings.SplitSeq(strings.TrimSpace(string(data)), "\n") {
		if rest, ok := strings.CutPrefix(line, "0::"); ok {
			own = rest
		}
	}
	if own == "" {
		return nil, errors.New("no cgroup v2 hierarchy")
	}
	root := filepath.Join(cgroupFS, own)
	if filepath.Base(own) == "service" { // started again inside its own subgroup
		root = filepath.Dir(root)
	}
	g := &Groups{root: root}
	service := filepath.Join(root, "service")
	if err := os.MkdirAll(service, 0o755); err != nil {
		return nil, fmt.Errorf("the service's control group isn't writable: %w", err)
	}
	if err := os.WriteFile(filepath.Join(service, "cgroup.procs"), []byte(strconv.Itoa(os.Getpid())), 0o644); err != nil {
		return nil, fmt.Errorf("can't move into the service's control group: %w", err)
	}
	if err := os.MkdirAll(filepath.Join(root, "jobs"), 0o755); err != nil {
		return nil, err
	}
	return g, nil
}

// New makes a job's group and returns its path and an open handle to start the command inside
// it (clone3's CLONE_INTO_CGROUP, so not even its first instant runs outside).
func (g *Groups) New(id string) (string, *os.File, error) {
	path := filepath.Join(g.root, "jobs", id)
	if err := os.Mkdir(path, 0o755); err != nil && !errors.Is(err, os.ErrExist) {
		return "", nil, err
	}
	f, err := os.Open(path)
	if err != nil {
		return "", nil, err
	}
	return path, f, nil
}

// Count is how many processes are in the group.
func (g *Groups) Count(path string) int {
	return len(pids(path))
}

// Kill stops everything in the group and removes it; it returns how many processes it stopped.
func (g *Groups) Kill(path string) (int, error) {
	n := len(pids(path))
	if err := os.WriteFile(filepath.Join(path, "cgroup.kill"), []byte("1"), 0o644); err != nil {
		// No cgroup.kill (kernels before 5.14): signal each; another user's processes may stay.
		for _, pid := range pids(path) {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	}
	deadline := time.Now().Add(3 * time.Second)
	for len(pids(path)) > 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if left := len(pids(path)); left > 0 {
		return n - left, fmt.Errorf("%d processes wouldn't stop", left)
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return n, err
	}
	return n, nil
}

// Leftovers are the groups of jobs from an earlier run (after a crash or restart).
func (g *Groups) Leftovers() []string {
	entries, err := os.ReadDir(filepath.Join(g.root, "jobs"))
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range entries {
		if e.IsDir() {
			out = append(out, filepath.Join(g.root, "jobs", e.Name()))
		}
	}
	return out
}

func pids(path string) []int {
	f, err := os.Open(filepath.Join(path, "cgroup.procs"))
	if err != nil {
		return nil
	}
	defer func() { _ = f.Close() }()
	var out []int
	s := bufio.NewScanner(f)
	for s.Scan() {
		if pid, err := strconv.Atoi(strings.TrimSpace(s.Text())); err == nil {
			out = append(out, pid)
		}
	}
	return out
}

// procAttr starts a command as its terminal's session leader, inside group when there is one.
func procAttr(group *os.File) *syscall.SysProcAttr {
	a := &syscall.SysProcAttr{Setsid: true, Setctty: true}
	if group != nil {
		a.UseCgroupFD = true
		a.CgroupFD = int(group.Fd())
	}
	return a
}

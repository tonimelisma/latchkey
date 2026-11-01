//go:build linux

package shell_test

import (
	"os"
	"os/exec"
	"os/user"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/linux/internal/shell"
	"github.com/tonimelisma/latchkey/linux/internal/tools"
)

// These run where the program has its own control group (the test container started by
// `make test-linux`, LATCHKEY_TEST_CGROUP=1); elsewhere they are skipped.
func needGroups(t *testing.T) {
	t.Helper()
	if os.Getenv("LATCHKEY_TEST_CGROUP") != "1" {
		t.Skip("needs a delegated control group: run with make test-linux")
	}
}

// pgrep reports whether a process with this exact command line runs, by anyone.
func running(marker string) bool {
	out, _ := exec.Command("pgrep", "-f", marker).Output()
	return strings.TrimSpace(string(out)) != ""
}

// A command's leftovers are stopped when it finishes, however they left: in the background, a
// new session, a double fork, nohup (FR-1032).
func TestLeftoversAreStopped(t *testing.T) {
	needGroups(t)
	e := setup(t)
	// The pause lets setsid and nohup take effect before bash exits and the terminal hangs up.
	out := e.do(e.run, tools.Args{"command": `sleep 301 & setsid sleep 302 & ( ( nohup sleep 303 >/dev/null 2>&1 & ) & ); sleep 0.5; echo started`})
	assert.Contains(t, out, "started")
	// How many are still there to stop varies: the terminal's hang-up ends some when bash exits.
	assert.Regexp(t, `Stopped \d+ process(es)? it left running`, out)
	assert.NotContains(t, out, "may not be stopped", "the control groups work here")
	require.Eventually(t, func() bool {
		return !running("sleep 301") && !running("sleep 302") && !running("sleep 303")
	}, 5*time.Second, 50*time.Millisecond, "nothing left running")
}

// Even what a command started with sudo, running as root, is stopped (FR-1032; the test user has
// passwordless sudo in the container).
func TestSudoLeftoversAreStopped(t *testing.T) {
	needGroups(t)
	if u, _ := user.Current(); u == nil || u.Uid == "0" {
		t.Skip("needs a non-root user with passwordless sudo")
	}
	e := setup(t)
	out := e.do(e.run, tools.Args{"command": `sudo sh -c 'sleep 304 &' ; sudo id -u`})
	assert.Regexp(t, `(?m)^0$`, out, "sudo works where allowed without a password")
	assert.Contains(t, out, "Stopped 1 process it left running")
	require.Eventually(t, func() bool { return !running("sleep 304") }, 5*time.Second, 50*time.Millisecond, "root's leftover stopped too")
}

// A command keeping its leftovers keeps them until the lease ends or Shell stops them.
func TestKeptLeftoversRunUntilStopped(t *testing.T) {
	needGroups(t)
	e := setup(t)
	// Its own session: a plain background job gets the terminal's hang-up when the shell ends.
	out := e.do(e.run, tools.Args{"command": `setsid -f sleep 305 >/dev/null 2>&1; echo bg`, "keep_minutes": 10})
	assert.Contains(t, out, "1 processes still running")
	assert.True(t, running("sleep 305"))
	e.sh.StopAll("test")
	require.Eventually(t, func() bool { return !running("sleep 305") }, 5*time.Second, 50*time.Millisecond)
}

// A sudo reached by its full path, which asks for a password at the terminal, is stopped at once
// with the hint (FR-1031). The container's second user needs a password for sudo.
func TestSudoPromptIsStopped(t *testing.T) {
	if os.Getenv("LATCHKEY_TEST_SUDO_PROMPT") != "1" {
		t.Skip("needs a user whose sudo asks for a password: run with make test-linux")
	}
	e := setup(t)
	start := time.Now()
	out := e.do(e.run, tools.Args{"command": "/usr/bin/sudo true", "wait": 20})
	assert.Less(t, time.Since(start), 10*time.Second)
	assert.Contains(t, out, shell.SudoHint)
	assert.Contains(t, out, "Stopped (sudo asked for a password)")
}

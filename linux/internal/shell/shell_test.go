package shell_test

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/linux/internal/config"
	"github.com/tonimelisma/latchkey/linux/internal/shell"
	"github.com/tonimelisma/latchkey/linux/internal/tools"
)

type env struct {
	t     *testing.T
	sh    *shell.Shell
	paths config.Paths
	run   tools.Tool
	check tools.Tool
}

func setup(t *testing.T) *env {
	t.Helper()
	home := t.TempDir()
	p := config.PathsFor(home, "", "", "")
	sh := shell.New(p)
	t.Cleanup(sh.Close)
	ts := sh.Tools()
	require.Len(t, ts, 2)
	return &env{t: t, sh: sh, paths: p, run: ts[0], check: ts[1]}
}

func text(r tools.Result) string {
	var b strings.Builder
	for _, c := range r.Content {
		if s, ok := c["text"].(string); ok {
			b.WriteString(s)
		}
	}
	return b.String()
}

func (e *env) do(tool tools.Tool, args tools.Args) string {
	e.t.Helper()
	return text(tool.Run(context.Background(), args))
}

var jobRE = regexp.MustCompile(`job (j[a-z2-7]+)`)

func TestRunAndFinish(t *testing.T) {
	e := setup(t)
	out := e.do(e.run, tools.Args{"command": `printf '\033[31mred\033[0m\n'; echo "tmp=$TMPDIR"; echo "scratch=$LATCHKEY_SCRATCH"; pwd; exit 3`})
	assert.Contains(t, out, "red\n", "colour codes removed")
	assert.NotContains(t, out, "\033")
	assert.Regexp(t, `tmp=`+regexp.QuoteMeta(e.paths.Jobs)+`/j[a-z2-7]+\n`, out, "its own scratch folder")
	assert.Contains(t, out, e.paths.Home+"\n", "runs in the home folder by default")
	assert.Contains(t, out, "(Exit status 3.")
	assert.Contains(t, strings.ToLower(out), "its scratch folder was deleted")
	m := regexp.MustCompile(`tmp=(\S+)`).FindStringSubmatch(out)
	require.NotNil(t, m)
	assert.NoDirExists(t, m[1])

	require.NoError(t, os.MkdirAll(filepath.Join(e.paths.Home, "proj"), 0o755))
	out = e.do(e.run, tools.Args{"command": "pwd", "folder": "~/proj"})
	assert.Contains(t, out, filepath.Join(e.paths.Home, "proj"))
	out = e.do(e.run, tools.Args{"command": "pwd", "folder": "/nowhere"})
	assert.Contains(t, out, "doesn't exist")
	out = e.do(e.run, tools.Args{})
	assert.Contains(t, out, "Give a command.")
}

func TestJobsKeepRunningAndTakeInput(t *testing.T) {
	e := setup(t)
	out := e.do(e.run, tools.Args{"command": `echo started; read -r answer; echo "you said $answer"; sleep 30`, "wait": 1})
	assert.Contains(t, out, "started")
	m := jobRE.FindStringSubmatch(out)
	require.NotNil(t, m, out)
	id := m[1]
	assert.Contains(t, e.sh.Footer(), id+" running", "every answer names running commands")

	out = e.do(e.run, tools.Args{"job": id, "input": "yes"})
	assert.Contains(t, out, "you said yes")
	assert.NotContains(t, out, "started", "only new output")

	list := e.do(e.check, tools.Args{})
	assert.Contains(t, list, id+": echo started;")

	out = e.do(e.run, tools.Args{"job": id, "stop": true})
	assert.Contains(t, out, "Stopped (stopped by Claude)")
	assert.Empty(t, e.sh.Footer())
	out = e.do(e.check, tools.Args{"job": id, "wait": 0})
	assert.Contains(t, out, "Stopped")
	out = e.do(e.check, tools.Args{"job": "jnope"})
	assert.Contains(t, out, `No job "jnope"`)
}

func TestCheckWaitsForTheEnd(t *testing.T) {
	e := setup(t)
	out := e.do(e.run, tools.Args{"command": "sleep 2; echo done", "wait": 1})
	id := jobRE.FindStringSubmatch(out)[1]
	start := time.Now()
	out = e.do(e.check, tools.Args{"job": id, "wait": 10})
	assert.Less(t, time.Since(start), 5*time.Second)
	assert.Contains(t, out, "done")
	assert.Contains(t, out, "(Exit status 0.")
}

func TestKeptLeftoversHaveALease(t *testing.T) {
	e := setup(t)
	out := e.do(e.run, tools.Args{"command": "echo hi", "keep_minutes": 5})
	assert.Contains(t, out, "Kept until ")
	assert.Contains(t, out, "its scratch folder "+e.paths.Jobs)
	assert.Contains(t, e.sh.Footer(), "kept until")
	e.sh.StopAll("test")
	assert.Empty(t, e.sh.Footer(), "turning Shell off removes kept leftovers too")
}

// sudo never waits for a password: the wrapper runs it with -n, and the answer says how the
// owner can allow it (FR-1031). -k makes sudo ignore cached credentials, so a password is always
// needed here; nothing runs as root.
func TestSudoAnswersAtOnce(t *testing.T) {
	if _, err := os.Stat("/usr/bin/sudo"); err != nil {
		t.Skip("no sudo here")
	}
	if exec.Command("/usr/bin/sudo", "-n", "true").Run() == nil {
		t.Skip("this user has passwordless sudo, so sudo never needs a password here")
	}
	e := setup(t)
	start := time.Now()
	out := e.do(e.run, tools.Args{"command": "sudo -k true", "wait": 20})
	assert.Less(t, time.Since(start), 10*time.Second, "never waits for a password")
	assert.Contains(t, out, "password is required")
	assert.Contains(t, out, shell.SudoHint)
	wrapper, err := os.ReadFile(filepath.Join(e.paths.Bin, "sudo"))
	require.NoError(t, err)
	assert.Contains(t, string(wrapper), "-n \"$@\"")
}

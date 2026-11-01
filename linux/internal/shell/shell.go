// Package shell is Shell on a Linux server (spec 010 FR-1030 to FR-1033, plan D9): the same two
// tools as the Mac's, commands in a bash login shell in a terminal, jobs that keep running, sudo
// that never waits for a password, and what a command leaves running stopped when it finishes
// unless Claude asked to keep it. There is no write fence (Toni, 2026-10-31: it blocks sudo).
package shell

import (
	"context"
	"crypto/rand"
	"encoding/base32"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"

	"github.com/tonimelisma/latchkey/linux/internal/config"
	"github.com/tonimelisma/latchkey/linux/internal/tools"
)

// Limits (as the Mac's, spec 004).
const (
	maxRunning   = 32
	maxWait      = 30
	maxKeep      = 24 * time.Hour
	finishedKept = 10 * time.Minute // finished jobs are listed this long
)

// Shell runs commands.
type Shell struct {
	paths  config.Paths
	groups *Groups // nil: leftovers can't be stopped reliably
	warn   string  // said in every Shell answer when groups is nil (FR-330's rule)
	bash   string
	sudo   string // the real sudo, "" if none
	now    func() time.Time

	mu   sync.Mutex
	jobs map[string]*job
	quit chan struct{}
}

type job struct {
	id, command, folder string
	cmd                 *exec.Cmd
	pty                 *os.File
	out                 *buffer
	done                chan struct{}
	exit                int
	started, finished   time.Time
	keep                time.Duration
	leaseUntil          time.Time
	scratch, group      string
	cleaned             bool
	stopped             string // why it was stopped, if it was
	leftover            string // what its cleanup did, for the answer
}

// New prepares Shell: the sudo wrapper, and the control groups (whose absence is said in every
// answer). It removes what an earlier run left (FR-324's rule).
func New(p config.Paths) *Shell {
	s := &Shell{paths: p, jobs: map[string]*job{}, now: time.Now, quit: make(chan struct{})}
	s.bash = firstExisting("/bin/bash", "/usr/bin/bash", "/bin/sh")
	s.sudo = firstExisting("/usr/bin/sudo", "/bin/sudo", "/usr/local/bin/sudo")
	if err := s.writeSudoWrapper(); err != nil {
		s.warn = "The sudo wrapper couldn't be written (" + err.Error() + "); sudo may wait for a password."
	}
	g, err := OpenGroups()
	if err != nil {
		s.warn = strings.TrimSpace(s.warn + " What commands leave running may not be stopped: " + err.Error() + ".")
	} else {
		s.groups = g
		for _, old := range g.Leftovers() {
			_, _ = g.Kill(old)
		}
	}
	_ = os.RemoveAll(p.Jobs) // scratch folders of an earlier run
	go s.reap()
	return s
}

func firstExisting(paths ...string) string {
	for _, p := range paths {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

// writeSudoWrapper puts a sudo first on every command's PATH that runs the real one with -n, so
// it answers at once instead of waiting for a password (FR-1031).
func (s *Shell) writeSudoWrapper() error {
	if s.sudo == "" {
		return nil
	}
	if err := os.MkdirAll(s.paths.Bin, 0o700); err != nil {
		return err
	}
	script := "#!/bin/sh\n# Latchkey: sudo never waits for a password here (spec 010 FR-1031).\nexec " + s.sudo + " -n \"$@\"\n"
	return config.WriteAtomic(filepath.Join(s.paths.Bin, "sudo"), []byte(script), 0o755)
}

// Tools are Shell's tools while it is on.
func (s *Shell) Tools() []tools.Tool {
	return []tools.Tool{
		{
			Def: tools.Make(tools.Spec{
				Name: "shell_run", Title: "Run a Command",
				Description: "Runs a command in bash (a login shell) on the server, as the owner's account. Waits up to wait seconds (default and most 30); " +
					"a longer command keeps running as a job (check it with shell_check). With job and input: types input into that job (then Enter unless " +
					"enter is false). With job and stop: stops it (Ctrl-C, then forcibly). sudo works for what the owner allowed without a password, and " +
					"answers at once otherwise; it never waits for one. Each command has its own scratch folder ($LATCHKEY_SCRATCH, also $TMPDIR), deleted " +
					"when it finishes. Whatever it leaves running is stopped when it finishes, unless keep_minutes asks to keep it (checking the job keeps " +
					"it longer; 24 hours at most).",
				Input: map[string]any{
					"command":      tools.String("The command line"),
					"folder":       tools.String("Run in this folder (default: home)"),
					"wait":         tools.Integer("Seconds to wait for it to finish (1 to 30, default 30)"),
					"keep_minutes": tools.Integer("Keep what it leaves running, and its scratch folder, this many minutes after it finishes (0 to 1440)"),
					"job":          tools.String("A running job's id, to type into or stop"),
					"input":        tools.String("With job: what to type"),
					"enter":        tools.Bool("With input: press Enter after (default true)"),
					"stop":         tools.Bool("With job: stop it"),
				},
				Destructive: true, OpenWorld: true, DeadlineMS: 45_000,
			}),
			Run: s.run,
		},
		{
			Def: tools.Make(tools.Spec{
				Name: "shell_check", Title: "Check Commands",
				Description: "With job: shows that job's new output since the last check and whether it has finished, waiting up to wait seconds; for a " +
					"job whose leftovers are kept, checking keeps them longer. Without: lists running jobs, those whose leftovers are kept, and those " +
					"finished in the last 10 minutes.",
				Input: map[string]any{
					"job":  tools.String("The job id from shell_run"),
					"wait": tools.Integer("Seconds to wait for more output or the end (0 to 30, default 10)"),
				},
				ReadOnly: true, DeadlineMS: 45_000,
			}),
			Run: s.check,
		},
	}
}

func (s *Shell) run(ctx context.Context, a tools.Args) tools.Result {
	if a.Has("job") {
		id, _ := a.String("job")
		j := s.job(id)
		if j == nil {
			return s.answer(tools.Failf("No job %q; shell_check lists the jobs.", id))
		}
		if stop, _ := a.Bool("stop", false); stop {
			s.stop(j, "stopped by Claude")
			<-j.done
			return s.answer(tools.Text(s.report(j, false)))
		}
		input, err := a.String("input")
		if err != nil || !a.Has("input") {
			return s.answer(tools.Failf("With job, give input to type or stop: true."))
		}
		enter, _ := a.Bool("enter", true)
		if enter {
			input += "\r"
		}
		if _, err := j.pty.Write([]byte(input)); err != nil {
			return s.answer(tools.Failf("Couldn't type into job %s: it has finished.", id))
		}
		return s.wait(ctx, j, 2)
	}
	command, err := a.String("command")
	if err != nil || strings.TrimSpace(command) == "" {
		return s.answer(tools.Failf("Give a command."))
	}
	wait, err := a.Int("wait", maxWait, 1, maxWait)
	if err != nil {
		return s.answer(tools.Failf("%v", err))
	}
	keep, err := a.Int("keep_minutes", 0, 0, 1440)
	if err != nil {
		return s.answer(tools.Failf("%v", err))
	}
	folder, _ := a.String("folder")
	j, err := s.start(command, folder, time.Duration(keep)*time.Minute)
	if err != nil {
		return s.answer(tools.Failf("%v", err))
	}
	return s.wait(ctx, j, wait)
}

// start launches a command.
func (s *Shell) start(command, folder string, keep time.Duration) (*job, error) {
	s.mu.Lock()
	running := 0
	for _, j := range s.jobs {
		if j.finished.IsZero() {
			running++
		}
	}
	s.mu.Unlock()
	if running >= maxRunning {
		return nil, fmt.Errorf("%d commands are running, the most at once; wait for one to finish or stop one", maxRunning)
	}
	dir := s.paths.Home
	if f := strings.TrimSpace(folder); f != "" {
		switch {
		case f == "~":
		case strings.HasPrefix(f, "~/"):
			dir = filepath.Join(s.paths.Home, f[2:])
		case filepath.IsAbs(f):
			dir = f
		default:
			dir = filepath.Join(s.paths.Home, f)
		}
	}
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		return nil, fmt.Errorf("the folder %s doesn't exist", dir)
	}
	id := newID()
	j := &job{id: id, command: command, folder: dir, out: &buffer{}, done: make(chan struct{}), keep: keep, started: s.now()}
	j.scratch = filepath.Join(s.paths.Jobs, id)
	if err := os.MkdirAll(j.scratch, 0o700); err != nil {
		return nil, fmt.Errorf("couldn't make the command's scratch folder: %w", err)
	}
	var groupFile *os.File
	if s.groups != nil {
		path, f, err := s.groups.New(id)
		if err == nil {
			j.group, groupFile = path, f
		}
	}
	cmd := exec.Command(s.bash, "-l", "-c", `PATH="$LATCHKEY_BIN:$PATH"; export PATH; eval "$LATCHKEY_COMMAND"`)
	cmd.Dir = dir
	cmd.Env = append(baseEnv(),
		"LATCHKEY_COMMAND="+command, "LATCHKEY_BIN="+s.paths.Bin, "LATCHKEY_JOB="+id,
		"LATCHKEY_SCRATCH="+j.scratch, "TMPDIR="+j.scratch, "TERM=xterm-256color",
	)
	j.out.notify = func() { s.stop(j, "sudo asked for a password") }
	f, err := pty.StartWithAttrs(cmd, &pty.Winsize{Rows: 50, Cols: 200}, procAttr(groupFile))
	if groupFile != nil {
		_ = groupFile.Close()
	}
	if err != nil {
		_ = os.RemoveAll(j.scratch)
		if j.group != "" {
			_, _ = s.groups.Kill(j.group)
		}
		return nil, fmt.Errorf("the command couldn't start: %w", err)
	}
	j.cmd, j.pty = cmd, f
	s.mu.Lock()
	s.jobs[id] = j
	s.mu.Unlock()
	go s.follow(j)
	return j, nil
}

// baseEnv is the service's environment without what each command sets itself.
func baseEnv() []string {
	var out []string
	for _, kv := range os.Environ() {
		name, _, _ := strings.Cut(kv, "=")
		switch name {
		case "TMPDIR", "TERM", "LATCHKEY_COMMAND", "LATCHKEY_BIN", "LATCHKEY_JOB", "LATCHKEY_SCRATCH", "NOTIFY_SOCKET", "INVOCATION_ID", "JOURNAL_STREAM":
			continue
		}
		out = append(out, kv)
	}
	if !slices.ContainsFunc(out, func(kv string) bool { return strings.HasPrefix(kv, "PATH=") }) {
		out = append(out, "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
	}
	return out
}

// follow copies the terminal's output and finishes the job when its command ends. The end is the
// command's own process exiting, not the terminal closing: what it left in the background may
// hold the terminal open for ever (and is stopped by the cleanup).
func (s *Shell) follow(j *job) {
	readDone := make(chan struct{})
	go func() {
		defer close(readDone)
		buf := make([]byte, 32<<10)
		for {
			n, err := j.pty.Read(buf)
			if n > 0 {
				_, _ = j.out.Write(buf[:n])
			}
			if err != nil {
				return
			}
		}
	}()
	err := j.cmd.Wait()
	select { // the last output still on its way
	case <-readDone:
	case <-time.After(200 * time.Millisecond):
		// A leftover still holds the terminal; the reader ends when the cleanup stops it. Closing
		// the terminal here doesn't wake a blocked read, so the job doesn't wait for it.
	}
	_ = j.pty.Close()
	exit := 0
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		exit = ee.ExitCode()
		if status, ok := ee.Sys().(syscall.WaitStatus); ok && status.Signaled() {
			exit = 128 + int(status.Signal())
		}
	}
	s.mu.Lock()
	j.exit, j.finished = exit, s.now()
	j.leaseUntil = j.finished.Add(j.keep)
	s.mu.Unlock()
	if j.keep == 0 {
		s.cleanup(j)
	}
	close(j.done)
}

// cleanup stops what the job left running and deletes its scratch folder (FR-1032, FR-1033).
func (s *Shell) cleanup(j *job) {
	s.mu.Lock()
	if j.cleaned {
		s.mu.Unlock()
		return
	}
	j.cleaned = true
	s.mu.Unlock()
	var parts []string
	switch {
	case j.group != "":
		n, err := s.groups.Kill(j.group)
		switch {
		case err != nil:
			parts = append(parts, fmt.Sprintf("stopped %d processes it left running, but %v", n, err))
		case n == 1:
			parts = append(parts, "stopped 1 process it left running")
		case n > 1:
			parts = append(parts, fmt.Sprintf("stopped %d processes it left running", n))
		default:
			parts = append(parts, "nothing was left running")
		}
	case j.cmd != nil && j.cmd.Process != nil:
		_ = syscall.Kill(-j.cmd.Process.Pid, syscall.SIGKILL) // its terminal's process group, at least
	}
	if err := os.RemoveAll(j.scratch); err == nil {
		parts = append(parts, "its scratch folder was deleted")
	}
	s.mu.Lock()
	j.leftover = strings.Join(parts, "; ")
	s.mu.Unlock()
}

// stop ends a running job: Ctrl-C to its terminal's process group, then forcibly.
func (s *Shell) stop(j *job, why string) {
	s.mu.Lock()
	if !j.finished.IsZero() || j.stopped != "" {
		s.mu.Unlock()
		return
	}
	j.stopped = why
	s.mu.Unlock()
	pid := j.cmd.Process.Pid
	_ = syscall.Kill(-pid, syscall.SIGINT)
	go func() {
		select {
		case <-j.done:
		case <-time.After(2 * time.Second):
			if j.group != "" {
				_, _ = s.groups.Kill(j.group)
			}
			_ = syscall.Kill(-pid, syscall.SIGKILL)
		}
	}()
}

// StopAll stops every job and removes every leftover: Shell turned off, paused, or the program
// stopping (FR-310's and FR-326's rules).
func (s *Shell) StopAll(why string) {
	s.mu.Lock()
	jobs := make([]*job, 0, len(s.jobs))
	for _, j := range s.jobs {
		jobs = append(jobs, j)
	}
	s.mu.Unlock()
	for _, j := range jobs {
		s.stop(j, why)
	}
	for _, j := range jobs {
		select {
		case <-j.done:
		case <-time.After(5 * time.Second):
		}
		s.cleanup(j)
	}
}

// Close stops everything and the reaper.
func (s *Shell) Close() {
	select {
	case <-s.quit:
	default:
		close(s.quit)
	}
	s.StopAll("Latchkey stopped")
}

func (s *Shell) job(id string) *job {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.jobs[strings.TrimSpace(id)]
}

// wait waits for the job to finish, up to seconds, and reports.
func (s *Shell) wait(ctx context.Context, j *job, seconds int) tools.Result {
	select {
	case <-j.done:
	case <-time.After(time.Duration(seconds) * time.Second):
	case <-ctx.Done():
	}
	finished := false
	select {
	case <-j.done:
		finished = true
	default:
	}
	return s.answer(tools.Text(s.report(j, !finished)))
}

// report is the job's new output and what became of it.
func (s *Shell) report(j *job, running bool) string {
	text, lost := j.out.unseen()
	text, cut := tail(text)
	var b strings.Builder
	if lost || cut {
		b.WriteString("(Earlier output left out.)\n")
	}
	b.WriteString(strings.TrimRight(text, "\n"))
	if b.Len() > 0 {
		b.WriteString("\n")
	}
	prompt, refused := j.out.sudo()
	if prompt || refused {
		b.WriteString(SudoHint + "\n")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if running {
		fmt.Fprintf(&b, "(Still running as job %s. Check it with shell_check; type into it or stop it with shell_run and job.)", j.id)
		return b.String()
	}
	status := fmt.Sprintf("Exit status %d", j.exit)
	if j.stopped != "" {
		status = "Stopped (" + j.stopped + ")"
	}
	switch {
	case j.cleaned:
		fmt.Fprintf(&b, "(%s. %s.)", status, capitalize(j.leftover))
	case !j.leaseUntil.IsZero():
		n := 0
		if j.group != "" {
			n = s.groups.Count(j.group)
		}
		fmt.Fprintf(&b, "(%s. Kept until %s: %d processes still running and its scratch folder %s.)",
			status, j.leaseUntil.Format("15:04"), n, j.scratch)
	default:
		fmt.Fprintf(&b, "(%s.)", status)
	}
	return b.String()
}

func capitalize(s string) string {
	if s == "" {
		return "Nothing to clean up"
	}
	return strings.ToUpper(s[:1]) + s[1:]
}

func (s *Shell) check(ctx context.Context, a tools.Args) tools.Result {
	wait, err := a.Int("wait", 10, 0, maxWait)
	if err != nil {
		return s.answer(tools.Failf("%v", err))
	}
	if !a.Has("job") {
		return s.answer(tools.Text(s.list()))
	}
	id, _ := a.String("job")
	j := s.job(id)
	if j == nil {
		return s.answer(tools.Failf("No job %q; shell_check without job lists them.", id))
	}
	s.mu.Lock()
	if !j.finished.IsZero() && !j.cleaned && j.keep > 0 { // checking renews the lease (FR-314)
		j.leaseUntil = min64(s.now().Add(j.keep), j.finished.Add(maxKeep))
	}
	s.mu.Unlock()
	if wait == 0 {
		select {
		case <-j.done:
			return s.answer(tools.Text(s.report(j, false)))
		default:
			return s.answer(tools.Text(s.report(j, true)))
		}
	}
	return s.wait(ctx, j, wait)
}

func min64(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}

func (s *Shell) list() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var lines []string
	for _, j := range s.jobs {
		state := "running since " + j.started.Format("15:04:05")
		switch {
		case !j.finished.IsZero() && !j.cleaned:
			state = fmt.Sprintf("finished (exit %d), leftovers kept until %s", j.exit, j.leaseUntil.Format("15:04"))
		case !j.finished.IsZero():
			state = fmt.Sprintf("finished at %s (exit %d)", j.finished.Format("15:04:05"), j.exit)
		}
		lines = append(lines, fmt.Sprintf("%s: %s — %s", j.id, oneLine(j.command), state))
	}
	if len(lines) == 0 {
		return "No jobs are running, kept, or finished in the last 10 minutes."
	}
	sort.Strings(lines)
	return strings.Join(lines, "\n")
}

func oneLine(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > 80 {
		return string(r[:79]) + "…"
	}
	return s
}

// Footer names the commands running or kept, for the end of every answer while there are any
// (FR-322's rule); "" when none.
func (s *Shell) Footer() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var parts []string
	for _, j := range s.jobs {
		switch {
		case j.finished.IsZero():
			parts = append(parts, j.id+" running")
		case !j.cleaned:
			parts = append(parts, j.id+" kept until "+j.leaseUntil.Format("15:04"))
		}
	}
	if len(parts) == 0 {
		return ""
	}
	sort.Strings(parts)
	return "Commands: " + strings.Join(parts, ", ")
}

// answer adds Shell's warning when leftovers can't be stopped reliably.
func (s *Shell) answer(r tools.Result) tools.Result {
	if s.warn != "" {
		r.Content = append(r.Content, tools.Content{"type": "text", "text": "\n(" + s.warn + ")"})
	}
	return r
}

// reap ends leases and forgets old finished jobs.
func (s *Shell) reap() {
	t := time.NewTicker(10 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-s.quit:
			return
		case <-t.C:
		}
		now := s.now()
		var due []*job
		s.mu.Lock()
		for id, j := range s.jobs {
			switch {
			case j.finished.IsZero():
			case !j.cleaned && now.After(j.leaseUntil):
				due = append(due, j)
			case j.cleaned && now.Sub(j.finished) > finishedKept && now.After(j.leaseUntil.Add(finishedKept)):
				delete(s.jobs, id)
			}
		}
		s.mu.Unlock()
		for _, j := range due {
			s.cleanup(j)
		}
	}
}

func newID() string {
	b := make([]byte, 5)
	_, _ = rand.Read(b)
	return "j" + strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b))
}

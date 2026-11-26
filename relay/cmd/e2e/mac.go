package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/tonimelisma/latchkey/relay/internal/e2erelay"
	"github.com/tonimelisma/latchkey/relay/internal/evals"
)

// e2eMacName is the name `e2e mac` pairs the Swift host test's Mac under.
const e2eMacName = "E2E Mac"

// macCheck is the Mac app's real capabilities on this Mac, served by the Swift host test
// (macos/Tests/E2EHostTests.swift), driven through a private relay with a real MCP client
// (spec 015 FR-1501). Meant for GitHub's throwaway Mac runner: it uses this Mac's real home
// folder, shell and Downloads, and cleans up what it made.
type macCheck struct {
	ctx     context.Context
	cs      *mcp.ClientSession
	control string
	marker  string
	// machine is the name the Mac was paired under, which the machines tool must list.
	machine string
}

// vmMacCheck is the checks' runner inside the test Mac, whose Latchkey prepare paired as
// testMacName.
func vmMacCheck(ctx context.Context, cs *mcp.ClientSession) *macCheck {
	return &macCheck{ctx: ctx, cs: cs, marker: randomWord(), machine: testMacName}
}

func macCmd(args []string) error {
	fs := flag.NewFlagSet("mac", flag.ContinueOnError)
	checks := fs.String("checks", "core,files,shell,browser", "comma-separated checks to run (from e2e pick)")
	update := fs.Bool("update-snapshots", false, "rewrite relay/e2e/toolsnaps/mac to match")
	snaps := fs.String("snapshots", "e2e/toolsnaps", "the snapshot folder")
	derived := fs.String("derived-data", "", "xcodebuild's derived data with a build-for-testing (then test-without-building)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	want := strings.Split(*checks, ",")
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Minute)
	defer cancel()

	o, err := newOwner(ctx, "mac-e2e@example.com")
	if err != nil {
		return err
	}
	defer o.close()
	code, err := o.browser.PairCode(o.relay.Base, e2eMacName)
	if err != nil {
		return err
	}
	if err := o.approveClient(ctx); err != nil {
		return err
	}

	step("starting the app's real capabilities (the Swift host test)")
	control := filepath.Join(o.dir, "control")
	if err := os.WriteFile(control, nil, 0o600); err != nil {
		return err
	}
	macos, err := filepath.Abs("../macos")
	if err != nil {
		return err
	}
	xargs := []string{"-project", "Latchkey.xcodeproj", "-scheme", "Latchkey", "-destination", "platform=macOS"}
	if *derived != "" {
		xargs = append(xargs, "-derivedDataPath", *derived, "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=",
			"test-without-building")
	} else {
		xargs = append(xargs, "-derivedDataPath", "build/DerivedData", "test")
	}
	xargs = append(xargs, "-only-testing:LatchkeyTests/E2EHostTests")
	test := exec.CommandContext(ctx, "xcodebuild", xargs...) //nolint:gosec // fixed program and arguments
	test.Dir = macos
	test.Env = append(os.Environ(),
		"TEST_RUNNER_LATCHKEY_E2E_RELAY="+o.relay.Base, "TEST_RUNNER_LATCHKEY_E2E_CODE="+code,
		"TEST_RUNNER_LATCHKEY_E2E_CONTROL="+control)
	logFile := filepath.Join(o.dir, "xcodebuild.log")
	out, err := os.Create(logFile) //nolint:gosec // our own temporary folder
	if err != nil {
		return err
	}
	defer func() { _ = out.Close() }()
	test.Stdout, test.Stderr = out, out
	if err := test.Start(); err != nil {
		return err
	}
	testDone := make(chan error, 1)
	go func() { testDone <- test.Wait() }()
	m := &macCheck{ctx: ctx, control: control, marker: randomWord(), machine: e2eMacName}
	fail := func(err error) error {
		m.send("done")
		select {
		case err := <-testDone:
			_ = err // the log below says why
		case <-time.After(30 * time.Second):
		}
		data, _ := os.ReadFile(logFile) //nolint:gosec // our own temporary folder
		return fmt.Errorf("%w\n--- xcodebuild log (tail) ---\n%s", err, tail(string(data), 60))
	}
	if err := o.relay.WaitOnline(ctx, o.email, 10*time.Minute); err != nil {
		return fail(fmt.Errorf("the app's capabilities never connected: %w", err))
	}
	step("the Mac connected")
	if m.cs, err = e2erelay.MCPClient(ctx, o.relay.Base, o.token, "e2e"); err != nil {
		return fail(err)
	}
	defer func() { _ = m.cs.Close() }()

	ran := map[string]func() error{
		"core":    func() error { return m.snapshots(filepath.Join(*snaps, "mac"), *update) },
		"files":   m.files,
		"shell":   m.shell,
		"browser": m.browser,
	}
	for _, name := range []string{"core", "files", "shell", "browser"} {
		if !slices.Contains(want, name) {
			continue
		}
		step("check: %s", name)
		if err := ran[name](); err != nil {
			return fail(fmt.Errorf("%s: %w", name, err))
		}
	}
	if slices.Contains(want, "core") {
		if err := m.turnedOff(); err != nil {
			return fail(err)
		}
	}
	// Last: the Mac leaves, and the answer comes at once (Constitution II).
	m.send("done")
	select {
	case err := <-testDone:
		if err != nil {
			data, _ := os.ReadFile(logFile) //nolint:gosec // our own temporary folder
			return fmt.Errorf("the Swift host test failed: %w\n%s", err, tail(string(data), 60))
		}
	case <-time.After(2 * time.Minute):
		return errors.New("the Swift host test never ended")
	}
	if slices.Contains(want, "core") {
		start := time.Now()
		res, err := m.call("files_find", map[string]any{"path": "~"})
		if err != nil {
			return err
		}
		if !strings.Contains(strings.ToLower(e2erelay.TextOf(res)), "offline") || time.Since(start) > 5*time.Second {
			return fmt.Errorf("after the Mac left: %q in %s, want the offline answer within 5 s", e2erelay.TextOf(res), time.Since(start))
		}
		step("the offline answer came in %s", time.Since(start).Round(time.Millisecond))
	}
	fmt.Println("PASS: mac", strings.Join(want, ","))
	return nil
}

func (m *macCheck) send(cmd string) {
	f, err := os.OpenFile(m.control, os.O_APPEND|os.O_WRONLY, 0o600) //nolint:gosec // our own control file
	if err != nil {
		return
	}
	_, _ = f.WriteString(cmd + "\n")
	_ = f.Close()
}

func (m *macCheck) call(tool string, args map[string]any) (*mcp.CallToolResult, error) {
	ctx, cancel := context.WithTimeout(m.ctx, 90*time.Second)
	defer cancel()
	return m.cs.CallTool(ctx, &mcp.CallToolParams{Name: tool, Arguments: args})
}

// text calls a tool and returns its text, failing on a tool error.
func (m *macCheck) text(tool string, args map[string]any) (string, error) {
	res, err := m.call(tool, args)
	if err != nil {
		return "", fmt.Errorf("%s: %w", tool, err)
	}
	t := e2erelay.TextOf(res)
	if res.IsError {
		return t, fmt.Errorf("%s %v answered an error: %s", tool, args, t)
	}
	return t, nil
}

func (m *macCheck) snapshots(dir string, update bool) error {
	tools, err := e2erelay.ListAllTools(m.ctx, m.cs)
	if err != nil {
		return err
	}
	own := slices.DeleteFunc(slices.Clone(tools), func(t *mcp.Tool) bool { return t.Name == "machines" })
	diffs, err := evals.CompareSnapshots(dir, own, update)
	if err != nil {
		return err
	}
	if !update {
		if err := evals.SnapError("mac", diffs); err != nil {
			return err
		}
	}
	step("%d Mac tools, snapshots compared", len(own))
	t, err := m.text("machines", map[string]any{})
	if err != nil {
		return err
	}
	if m.machine == "" || !strings.Contains(t, m.machine) {
		return fmt.Errorf("machines doesn't list the Mac %q: %q", m.machine, t)
	}
	return nil
}

func (m *macCheck) files() error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	dir := filepath.Join(home, "latchkey-e2e-"+m.marker)
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(dir) }()
	tilde := "~/latchkey-e2e-" + m.marker
	if err := os.WriteFile(filepath.Join(dir, "note.txt"), []byte("e2e marker "+m.marker+"\n"), 0o600); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "picture.png"), testPNG(), 0o600); err != nil {
		return err
	}

	t, err := m.text("files_find", map[string]any{"path": tilde})
	if err != nil {
		return err
	}
	if !strings.Contains(t, "note.txt") || !strings.Contains(t, "picture.png") {
		return fmt.Errorf("files_find listed %q", t)
	}
	step("files_find listed the folder")
	if t, err = m.text("files_read", map[string]any{"path": tilde + "/note.txt"}); err != nil {
		return err
	}
	if !strings.Contains(t, m.marker) {
		return fmt.Errorf("files_read: %q", t)
	}
	res, err := m.call("files_read", map[string]any{"path": tilde + "/picture.png"})
	if err != nil {
		return err
	}
	if res.IsError || !slices.ContainsFunc(res.Content, func(c mcp.Content) bool { _, ok := c.(*mcp.ImageContent); return ok }) {
		return fmt.Errorf("files_read of a picture gave no image: %q", e2erelay.TextOf(res))
	}
	step("files_read read a text and a picture")
	if _, err := m.text("files_change", map[string]any{"action": "write", "path": tilde + "/new.txt", "text": "written by e2e"}); err != nil {
		return err
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "new.txt")); string(b) != "written by e2e" { //nolint:gosec // our folder
		return fmt.Errorf("after write, new.txt holds %q", b)
	}
	if _, err := m.text("files_change", map[string]any{"action": "edit", "path": tilde + "/note.txt", "find": "marker", "text": "MARK"}); err != nil {
		return err
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "note.txt")); !strings.Contains(string(b), "e2e MARK ") { //nolint:gosec // our folder
		return fmt.Errorf("after edit, note.txt holds %q", b)
	}
	if _, err := m.text("files_change", map[string]any{"action": "trash", "path": tilde + "/new.txt"}); err != nil {
		return err
	}
	if _, err := os.Stat(filepath.Join(dir, "new.txt")); !os.IsNotExist(err) {
		return errors.New("new.txt still there after trash")
	}
	step("files_change wrote, edited and trashed, as seen on disk")
	return nil
}

// pageRE finds the name an answer gives Claude's page: page "pk3wz" (OwnPages: p and four of
// its letters and digits).
var pageRE = regexp.MustCompile(`page "(p[a-z0-9]{4})"`)

var jobRE = regexp.MustCompile(`\b(job\d+)\b`) // ShellJobs names jobs job1, job2, …

func (m *macCheck) shell() error {
	t, err := m.text("shell_run", map[string]any{"command": "echo $((6*7)); sw_vers -productName"})
	if err != nil {
		return err
	}
	if !strings.Contains(t, "42") || !strings.Contains(t, "macOS") {
		return fmt.Errorf("shell_run: %q", t)
	}
	step("shell_run ran a command in the login shell")
	t, err = m.text("shell_run", map[string]any{"command": "sleep 4; echo late-" + m.marker, "wait": 1})
	if err != nil {
		return err
	}
	g := jobRE.FindStringSubmatch(t)
	if g == nil {
		return fmt.Errorf("a long command didn't become a job: %q", t)
	}
	step("the long command became a job: %q", short(t))
	job := g[1]
	deadline := time.Now().Add(60 * time.Second)
	for {
		t, err = m.text("shell_check", map[string]any{"job": job, "wait": 10})
		if err != nil {
			return err
		}
		if strings.Contains(t, "late-"+m.marker) {
			break
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("shell_check never showed the job's output: %q", t)
		}
	}
	step("shell_check showed the job's output")
	return nil
}

func (m *macCheck) browser() error {
	p, err := startPages(m.ctx, m.marker)
	if err != nil {
		return err
	}
	defer p.close()
	t, err := m.text("browser_look", map[string]any{"url": p.base + "/"})
	if err != nil {
		return err
	}
	page := ""
	if g := pageRE.FindStringSubmatch(t); g != nil {
		page = g[1]
	}
	if page == "" || !strings.Contains(t, "Page marker "+m.marker) {
		step("browser_look answered: %q", short(t))
		return fmt.Errorf("browser_look of the served page: %q", t)
	}
	step("browser_look opened the served page as %s", page)
	reveal := refFor(t, "Reveal")
	field := refFor(t, "Search words")
	if reveal == "" || field == "" {
		return fmt.Errorf("no reference for the Reveal button or the search field in %q", t)
	}
	if _, err := m.text("browser_act", map[string]any{"action": "click", "page": page, "ref": reveal}); err != nil {
		return err
	}
	if t, err = m.text("browser_look", map[string]any{"page": page}); err != nil {
		return err
	}
	if !strings.Contains(t, "Revealed 42") {
		return fmt.Errorf("after the click the page says %q", t)
	}
	step("browser_act clicked, and the page changed")
	if _, err := m.text("browser_act", map[string]any{"action": "type", "page": page, "ref": field, "text": "hello e2e", "submit": true}); err != nil {
		return err
	}
	if !waitFor(20*time.Second, func() bool { return p.saw("/search?q=hello+e2e") }) {
		return fmt.Errorf("the served page never got the typed search (saw %v)", p.seen())
	}
	step("browser_act typed into a field and sent the form")
	home, _ := os.UserHomeDir()
	before := time.Now().Add(-time.Second)
	if _, err := m.text("browser_act", map[string]any{"action": "download", "page": page, "url": p.base + "/statement.txt"}); err != nil {
		return err
	}
	var saved string
	if !waitFor(30*time.Second, func() bool {
		saved = newestWith(filepath.Join(home, "Downloads"), before, "statement "+m.marker)
		return saved != ""
	}) {
		return errors.New("no downloaded statement in ~/Downloads")
	}
	_ = os.Remove(saved)
	step("browser_act download saved the file to Downloads")
	_, _ = m.text("browser_act", map[string]any{"action": "close", "page": page})
	return nil
}

// turnedOff: a capability turned off disappears from Claude's list, and comes back (Constitution
// III, FR-1501).
func (m *macCheck) turnedOff() error {
	listed := func() []string {
		t, err := e2erelay.ListAllTools(m.ctx, m.cs)
		if err != nil {
			return nil
		}
		return toolNames(t)
	}
	m.send("off files")
	if !waitFor(15*time.Second, func() bool { return !slices.Contains(listed(), "files_read") }) {
		return errors.New("files_read still listed after Files was turned off (Constitution III)")
	}
	m.send("on files")
	if !waitFor(15*time.Second, func() bool { return slices.Contains(listed(), "files_read") }) {
		return errors.New("files_read didn't come back after Files was turned on")
	}
	step("Files turned off disappeared from the list, and came back")
	return nil
}

// refFor returns the first element reference (e12) on the line that names label.
func refFor(page, label string) string {
	for line := range strings.SplitSeq(page, "\n") {
		if strings.Contains(line, label) {
			if r := regexp.MustCompile(`\be\d+\b`).FindString(line); r != "" {
				return r
			}
		}
	}
	return ""
}

func newestWith(dir string, since time.Time, content string) string {
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		info, err := e.Info()
		if err != nil || info.ModTime().Before(since) || e.IsDir() {
			continue
		}
		p := filepath.Join(dir, e.Name())
		if b, err := os.ReadFile(p); err == nil && strings.Contains(string(b), content) { //nolint:gosec // Downloads, a file we caused
			return p
		}
	}
	return ""
}

// pages serves the test pages a browser check uses (FR-1505): nothing reaches a real site.
type pages struct {
	base string
	srv  *http.Server
	mu   sync.Mutex
	got  []string
}

func startPages(ctx context.Context, marker string) (*pages, error) {
	l, err := (&net.ListenConfig{}).Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	p := &pages{base: "http://" + l.Addr().String()}
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		p.record(r)
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = fmt.Fprintf(w, `<!doctype html><html><head><title>E2E page</title></head><body>
<h1>Page marker %s</h1>
<p id="out">Not yet</p>
<button onclick="document.getElementById('out').textContent='Revealed '+(6*7)">Reveal</button>
<form action="/search" method="get"><label>Search words <input name="q" aria-label="Search words"></label></form>
<a href="/statement.txt" download>Statement</a>
</body></html>`, marker)
	})
	mux.HandleFunc("/search", func(w http.ResponseWriter, r *http.Request) {
		p.record(r)
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = fmt.Fprint(w, `<!doctype html><title>Results</title><p>Results</p>`)
	})
	mux.HandleFunc("/statement.txt", func(w http.ResponseWriter, r *http.Request) {
		p.record(r)
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Content-Disposition", `attachment; filename="statement.txt"`)
		_, _ = fmt.Fprintf(w, "statement %s\n", marker)
	})
	p.srv = &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() { _ = p.srv.Serve(l) }()
	return p, nil
}

func (p *pages) record(r *http.Request) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.got = append(p.got, r.URL.RequestURI())
}

func (p *pages) saw(uri string) bool { return slices.Contains(p.seen(), uri) }

func (p *pages) seen() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return slices.Clone(p.got)
}

func (p *pages) close() { _ = p.srv.Close() }

func randomWord() string {
	b := make([]byte, 4)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func testPNG() []byte { return testPNGSized(32) }

// testPNGSized is a test picture of size × size pixels (bigger is a bigger file).
func testPNGSized(size int) []byte {
	img := image.NewRGBA(image.Rect(0, 0, size, size))
	for x := range size {
		for y := range size {
			img.Set(x, y, color.RGBA{R: uint8(x * 7), G: uint8(x * y), B: uint8(y * 5), A: 255}) //nolint:gosec // small numbers
		}
	}
	var b bytes.Buffer
	_ = png.Encode(&b, img)
	return b.Bytes()
}

func tail(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

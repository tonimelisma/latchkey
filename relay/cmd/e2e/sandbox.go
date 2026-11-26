package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/tonimelisma/latchkey/relay/internal/e2e"
	"github.com/tonimelisma/latchkey/relay/internal/e2erelay"
)

// The sandbox Mac (spec 016 FR-1605, FR-1606, plan D3): `make sandbox` starts or reuses a copy
// of the eval image with the local build installed, and runs `e2e sandbox` inside it. The image's
// Latchkey is paired with the private relay kept in the image (prepare); here that relay listens
// behind a proxy on the address Latchkey dials, so a check can cut the network silently.
const (
	sandboxRelayListen = "127.0.0.1:8444"
	sandboxAppID       = "net.melisma.latchkey" // the Release identity (macos/project.yml)
	sandboxAppPath     = "/Applications/Latchkey.app"
)

// sandboxOrder is every check, in the order they run: the capabilities first, then the checks
// that disturb the connection (moved from cmd/maccheck), each leaving the copy as it found it.
var sandboxOrder = []string{
	"tools", "files", "shell", "browser", "notes", "calendar", "reminders", "contacts", "computer",
	"location", "messages", "mail", "whatsapp", "logins",
	"turned-off", "offline", "relay-restart", "network-cut", "suspended", "battery", "pair-preview",
}

// sandboxSkips are the checks the image can't exercise, with the reason each is reported.
var sandboxSkips = map[string]string{
	"location": "a virtual Mac has no Wi-Fi to measure its location from",
	"messages": "the image has no test iMessage account",
	"mail":     "the image has no test Mail account",
	"whatsapp": "no test machine has WhatsApp signed in",
	"logins":   "the image's Passwords hold no test logins",
	"pair-preview": "the copy's Latchkey is paired once, in the image; pairing it again in each run " +
		"would change the image's pairing (the preview itself: relay tests)",
}

// sandboxCheck is one check's outcome in the result file.
type sandboxCheck struct {
	Name    string  `json:"name"`
	Result  string  `json:"result"` // passed, failed, skipped
	Why     string  `json:"why,omitempty"`
	Seconds float64 `json:"seconds"`
}

// sandboxResult is e2e-results/sandbox-<build>-<time>.json.
type sandboxResult struct {
	Kind               string         `json:"kind"` // "sandbox"
	Format             int            `json:"format"`
	Build              string         `json:"build"`
	Latchkey           string         `json:"latchkey"`
	MacOS              string         `json:"macos"`
	Started            time.Time      `json:"started"`
	Finished           time.Time      `json:"finished"`
	Setup              string         `json:"setup,omitempty"`
	MissingPermissions []string       `json:"missing_permissions,omitempty"`
	Checks             []sandboxCheck `json:"checks"`
}

// failed counts the failed checks.
func (r sandboxResult) failed() int {
	n := 0
	for _, c := range r.Checks {
		if c.Result == "failed" {
			n++
		}
	}
	return n
}

// selectChecks turns -checks into the checks to run, in sandboxOrder; empty or "all" is every one.
func selectChecks(list string) ([]string, error) {
	list = strings.TrimSpace(list)
	if list == "" || list == "all" {
		return slices.Clone(sandboxOrder), nil
	}
	want := map[string]bool{}
	for n := range strings.SplitSeq(list, ",") {
		n = strings.TrimSpace(n)
		if n == "" {
			continue
		}
		if !slices.Contains(sandboxOrder, n) {
			return nil, fmt.Errorf("unknown check %q (the checks: %s)", n, strings.Join(sandboxOrder, ", "))
		}
		want[n] = true
	}
	if len(want) == 0 {
		return nil, errors.New("no checks named")
	}
	return slices.DeleteFunc(slices.Clone(sandboxOrder), func(n string) bool { return !want[n] }), nil
}

// summaryLine is the one line printed per check.
func summaryLine(c sandboxCheck) string {
	switch c.Result {
	case "passed":
		return fmt.Sprintf("PASS %s (%.1f s)", c.Name, c.Seconds)
	case "skipped":
		return fmt.Sprintf("SKIP %s: %s", c.Name, c.Why)
	default:
		return fmt.Sprintf("FAIL %s (%.1f s): %s", c.Name, c.Seconds, c.Why)
	}
}

// idRE finds an id in a tool's answer: "(id x-coredata://…/p12; …)", "id: …", "id ABC".
var idRE = regexp.MustCompile(`\bid:? ([^\s;)]+)`)

// idOn returns the id on the first line of an answer that names label.
func idOn(answer, label string) string {
	for line := range strings.SplitSeq(answer, "\n") {
		if strings.Contains(line, label) {
			if g := idRE.FindStringSubmatch(line); g != nil {
				return strings.TrimSuffix(g[1], ".")
			}
		}
	}
	return ""
}

// sandboxCmd runs inside the sandbox copy: the stored relay behind its proxy, a sign-in with the
// stored passkey, the permissions probe, then each selected check; the result goes to -out.
func sandboxCmd(args []string) error {
	fs := flag.NewFlagSet("sandbox", flag.ContinueOnError)
	out := fs.String("out", "sandbox.json", "where to write the result")
	build := fs.String("build", "", "what was built (the commit), for the result")
	list := fs.String("checks", "all", "comma-separated checks to run: "+strings.Join(sandboxOrder, ","))
	if err := fs.Parse(args); err != nil {
		return err
	}
	names, err := selectChecks(*list)
	if err != nil {
		return err
	}
	res := sandboxResult{
		Kind: "sandbox", Format: 1, Build: *build, Started: time.Now().UTC(),
		Latchkey: appVersion(), MacOS: run1("/usr/bin/sw_vers", "-productVersion") + " (sandbox copy)",
	}
	s := &sandbox{}
	err = s.run(&res, names)
	if err != nil {
		res.Setup = err.Error()
	}
	res.Finished = time.Now().UTC()
	b, merr := json.MarshalIndent(res, "", "  ")
	if merr != nil {
		return errors.Join(err, merr)
	}
	if werr := os.WriteFile(*out, b, 0o600); werr != nil {
		return errors.Join(err, werr)
	}
	if err != nil {
		return err
	}
	if n := res.failed(); n > 0 {
		return fmt.Errorf("%d of %d checks failed (above)", n, len(res.Checks))
	}
	fmt.Printf("PASS: sandbox, %d checks in %s\n", len(res.Checks), res.Finished.Sub(res.Started).Round(time.Second))
	return nil
}

type sandbox struct {
	ctx   context.Context
	dir   string
	relay *e2erelay.Private
	px    *cutProxy
	b     *e2e.Browser
	token string
	cs    *mcp.ClientSession
	m     *macCheck
	fx    *fixtures
}

func (s *sandbox) run(res *sandboxResult, names []string) error {
	var cancel func()
	s.ctx, cancel = context.WithTimeout(context.Background(), 20*time.Minute)
	defer cancel()
	var err error
	if s.dir, err = stateDir(); err != nil {
		return err
	}
	keys, err := os.ReadFile(filepath.Join(s.dir, "passkey.json"))
	if err != nil {
		return fmt.Errorf("the image has no stored account (run eval-image.sh again): %w", err)
	}
	if s.relay, err = startStateRelayAt(s.ctx, s.dir, sandboxRelayListen); err != nil {
		return err
	}
	defer func() { s.relay.Close() }()
	if s.px, err = newCutProxy(s.ctx, relayListen, sandboxRelayListen); err != nil {
		return fmt.Errorf("the proxy on %s: %w", relayListen, err)
	}
	defer s.px.close()
	// What an earlier run that stopped half-way may have left: a suspended account, a
	// capability turned off.
	_, _, _ = s.relay.DB.UnsuspendUser(s.ctx, ownerEmail, "e2e-sandbox", time.Now())
	if err := s.restoreLevels(); err != nil {
		return err
	}
	if s.b, err = e2e.NewBrowser(s.ctx); err != nil {
		return err
	}
	defer s.b.Close()
	if err := s.b.AddPasskeys(keys, ownerEmail); err != nil {
		return err
	}
	step("waiting for the sandbox copy's Latchkey to connect")
	if err := s.relay.WaitOnline(s.ctx, ownerEmail, 3*time.Minute); err != nil {
		return fmt.Errorf("latchkey in the sandbox copy never connected to its relay (is it running and paired?): %w", err)
	}
	if s.token, err = s.b.Token(s.ctx, relayURL); err != nil {
		return fmt.Errorf("sign-in with the stored passkey: %w", err)
	}
	if err := s.connect(); err != nil {
		return err
	}
	defer func() { _ = s.cs.Close() }()
	if s.fx, err = newFixtures(nil); err != nil {
		return err
	}
	if res.MissingPermissions = probePermissions(s.ctx, s.cs); len(res.MissingPermissions) > 0 {
		return fmt.Errorf("the sandbox image is missing permissions: %s (run eval-image.sh again)", strings.Join(res.MissingPermissions, ", "))
	}
	checks := s.checkFuncs()
	for _, n := range names {
		c := sandboxCheck{Name: n}
		if why, skip := sandboxSkips[n]; skip {
			c.Result, c.Why = "skipped", why
		} else {
			step("check: %s", n)
			start := time.Now()
			if err := checks[n](); err != nil {
				c.Result, c.Why = "failed", err.Error()
			} else {
				c.Result = "passed"
			}
			c.Seconds = time.Since(start).Round(100 * time.Millisecond).Seconds()
		}
		fmt.Println(summaryLine(c))
		res.Checks = append(res.Checks, c)
	}
	return nil
}

// checkFuncs is what each check that isn't skipped runs.
func (s *sandbox) checkFuncs() map[string]func() error {
	return map[string]func() error{
		"tools":         s.m.tools,
		"files":         func() error { return s.m.files() },
		"shell":         func() error { return s.m.shell() },
		"browser":       func() error { return s.m.browser() },
		"notes":         s.notes,
		"calendar":      s.calendar,
		"reminders":     s.reminders,
		"contacts":      s.contacts,
		"computer":      s.computer,
		"turned-off":    s.turnedOff,
		"offline":       s.offline,
		"relay-restart": s.relayRestart,
		"network-cut":   s.networkCut,
		"suspended":     s.suspended,
		"battery":       s.battery,
	}
}

// connect (again) opens the MCP session; a check that cut or restarted the relay calls it after.
func (s *sandbox) connect() error {
	if s.cs != nil {
		_ = s.cs.Close()
	}
	cs, err := e2erelay.MCPClient(s.ctx, relayURL, s.token, "e2e-sandbox")
	if err != nil {
		return err
	}
	s.cs = cs
	if s.m == nil {
		s.m = vmMacCheck(s.ctx, cs)
	}
	s.m.cs = cs
	return nil
}

func (s *sandbox) online() bool {
	d, err := s.relay.NewestDevice(s.ctx, ownerEmail)
	return err == nil && s.relay.Server.Hub.Online(d)
}

// waitOnline waits up to 90 s for the Mac to connect, and says how long it took.
func (s *sandbox) waitOnline() (time.Duration, error) {
	const within = 90 * time.Second
	start := time.Now()
	if !waitFor(within, s.online) {
		return time.Since(start), fmt.Errorf("the Mac didn't connect within %s", within)
	}
	return time.Since(start), nil
}

// fixture runs fixture lines, stopping at the first that fails.
func (s *sandbox) fixture(lines ...string) error {
	for _, l := range lines {
		if err := s.fx.do(l); err != nil {
			return fmt.Errorf("%s: %w", l, err)
		}
	}
	return nil
}

// holds checks an end state with the fixture's own reading of the app (not Latchkey's).
func (s *sandbox) holds(area, verb string, args ...string) error {
	why, err := s.fx.checkWords(area, verb, args)
	if err != nil {
		return fmt.Errorf("check %s %s %v: %w", area, verb, args, err)
	}
	if why != "" {
		return errors.New(why)
	}
	return nil
}

func (s *sandbox) notes() error {
	if err := s.fixture("sweep notes", "fixture notes shopping"); err != nil {
		return err
	}
	defer func() { _ = s.fx.do("sweep notes") }()
	t, err := s.m.text("notes_find", map[string]any{"query": "Shopping list", "folder": evalName})
	if err != nil {
		return err
	}
	id := idOn(t, "Shopping list")
	if id == "" {
		return fmt.Errorf("notes_find didn't list the shopping list with its id: %q", short(t))
	}
	if t, err = s.m.text("notes_read", map[string]any{"id": id}); err != nil {
		return err
	}
	if !strings.Contains(t, "eggs") {
		return fmt.Errorf("notes_read of the shopping list: %q", short(t))
	}
	added := "sandbox " + s.m.marker
	if _, err := s.m.text("notes_change", map[string]any{"action": "append", "id": id, "text": added}); err != nil {
		return err
	}
	if err := s.holds("notes", "body-contains", "Shopping list", added); err != nil {
		return err
	}
	title := "Sandbox " + s.m.marker
	t, err = s.m.text("notes_change", map[string]any{"action": "create", "folder": evalName, "title": title, "text": "made by the sandbox check"})
	if err != nil {
		return err
	}
	if err := s.holds("notes", "exists", title); err != nil {
		return err
	}
	if id = idOn(t, title); id == "" {
		return fmt.Errorf("notes_change create gave no id: %q", short(t))
	}
	if _, err := s.m.text("notes_change", map[string]any{"action": "delete", "id": id}); err != nil {
		return err
	}
	if err := s.holds("notes", "missing", title); err != nil {
		return err
	}
	step("notes: found, read, appended to, created and deleted, as Notes shows")
	return nil
}

func (s *sandbox) calendar() error {
	if err := s.fixture("sweep calendar", "fixture calendar team-sync"); err != nil {
		return err
	}
	defer func() { _ = s.fx.do("sweep calendar") }()
	today := time.Now()
	day := func(n int) string { return today.AddDate(0, 0, n).Format("2006-01-02") }
	t, err := s.m.text("calendar_find", map[string]any{"calendar": evalName, "query": "Team sync", "from": day(0), "to": day(3)})
	if err != nil {
		return err
	}
	if !strings.Contains(t, "Team sync") {
		return fmt.Errorf("calendar_find didn't list tomorrow's Team sync: %q", short(t))
	}
	title := "Sandbox " + s.m.marker
	if _, err := s.m.text("calendar_change", map[string]any{
		"action": "create", "calendar": evalName, "title": title, "start": day(1) + "T14:00", "end": day(1) + "T14:30",
	}); err != nil {
		return err
	}
	if err := s.holds("calendar", "event-at", title, "tomorrow", "14:00"); err != nil {
		return err
	}
	step("calendar: found an event and created one, as Calendar shows")
	return nil
}

func (s *sandbox) reminders() error {
	if err := s.fixture("sweep reminders", "fixture reminders chores"); err != nil {
		return err
	}
	defer func() { _ = s.fx.do("sweep reminders") }()
	t, err := s.m.text("reminders_find", map[string]any{"list": evalName})
	if err != nil {
		return err
	}
	id := idOn(t, "Buy stamps")
	if id == "" {
		return fmt.Errorf("reminders_find didn't list Buy stamps with its id: %q", short(t))
	}
	if _, err := s.m.text("reminders_change", map[string]any{"action": "complete", "id": id}); err != nil {
		return err
	}
	if err := s.holds("reminders", "completed", "Buy stamps"); err != nil {
		return err
	}
	if err := s.holds("reminders", "not-completed", "Pay rent"); err != nil {
		return err
	}
	title := "Sandbox " + s.m.marker
	due := time.Now().AddDate(0, 0, 3).Format("2006-01-02")
	if _, err := s.m.text("reminders_change", map[string]any{"action": "create", "list": evalName, "title": title, "due": due}); err != nil {
		return err
	}
	if err := s.holds("reminders", "due-on", title, "in-3-days"); err != nil {
		return err
	}
	step("reminders: completed one, left the other, created one due in 3 days, as Reminders shows")
	return nil
}

func (s *sandbox) contacts() error {
	if err := s.fixture("sweep contacts", "fixture contacts jordan"); err != nil {
		return err
	}
	defer func() { _ = s.fx.do("sweep contacts") }()
	t, err := s.m.text("contacts_find", map[string]any{"query": "Evaltest"})
	if err != nil {
		return err
	}
	id := idOn(t, "Jordan")
	if id == "" {
		return fmt.Errorf("contacts_find didn't list Jordan Evaltest with an id: %q", short(t))
	}
	email := "jordan." + s.m.marker + "@example.com"
	if _, err := s.m.text("contacts_change", map[string]any{"action": "update", "id": id, "emails": []any{email}}); err != nil {
		return err
	}
	if err := s.holds("contacts", "has-email", "Jordan Evaltest", email); err != nil {
		return err
	}
	step("contacts: found a card and changed its email, as Contacts shows")
	return nil
}

func (s *sandbox) computer() error {
	t, err := s.m.text("computer_look", map[string]any{"show": "apps"})
	if err != nil {
		return err
	}
	if !strings.Contains(t, "Finder") {
		return fmt.Errorf("computer_look apps doesn't list Finder: %q", short(t))
	}
	res, err := s.m.call("computer_look", map[string]any{})
	if err != nil {
		return err
	}
	if res.IsError || !slices.ContainsFunc(res.Content, func(c mcp.Content) bool { _, ok := c.(*mcp.ImageContent); return ok }) {
		return fmt.Errorf("computer_look gave no screenshot: %q", short(e2erelay.TextOf(res)))
	}
	step("computer: listed the apps and took a screenshot (of the copy's own screen)")
	return nil
}

// The connection checks, moved from cmd/maccheck (plan D2, D3).

func (s *sandbox) levelsBackup() string { return filepath.Join(s.dir, "prefs-before-turned-off.plist") }

// restoreLevels puts back the settings a turned-off check saved, if they are still there.
func (s *sandbox) restoreLevels() error {
	backup := s.levelsBackup()
	if _, err := os.Stat(backup); err != nil {
		return nil //nolint:nilerr // nothing saved: nothing to put back
	}
	step("putting back the settings an earlier run saved")
	if err := quitApp(); err != nil {
		return err
	}
	if err := runQuiet("/usr/bin/defaults", "import", sandboxAppID, backup); err != nil {
		return err
	}
	if err := os.Remove(backup); err != nil {
		return err
	}
	return openApp()
}

// turnedOff: a capability turned off disappears from Claude's list, and comes back
// (Constitution III). Latchkey is quit, Files set off in its settings, and started again.
func (s *sandbox) turnedOff() error {
	// files_read listed or not, once the Mac's tools are in (shell_run listed): right after a
	// start the list can be empty for a moment, which isn't "turned off".
	files := func(want bool) func() bool {
		return func() bool {
			t, err := e2erelay.ListAllTools(s.ctx, s.cs)
			names := toolNames(t)
			return err == nil && slices.Contains(names, "shell_run") && slices.Contains(names, "files_read") == want
		}
	}
	if err := runQuiet("/usr/bin/defaults", "export", sandboxAppID, s.levelsBackup()); err != nil {
		return err
	}
	if err := quitApp(); err != nil {
		return err
	}
	if err := runQuiet("/usr/bin/defaults", "write", sandboxAppID, "capabilityLevels", "-dict-add", "files", "off"); err != nil {
		return err
	}
	if err := openApp(); err != nil {
		return err
	}
	if _, err := s.waitOnline(); err != nil {
		return err
	}
	if !waitFor(10*time.Second, files(false)) {
		_ = s.restoreLevels()
		return errors.New("files_read still listed after Files was turned off (Constitution III)")
	}
	if err := s.restoreLevels(); err != nil {
		return err
	}
	if _, err := s.waitOnline(); err != nil {
		return err
	}
	if !waitFor(10*time.Second, files(true)) {
		return errors.New("files_read didn't come back after Files was turned on again")
	}
	step("Files turned off disappeared from the list, and came back")
	return nil
}

// offline: when the Mac leaves, Claude hears so at once (Constitution II, spec 001 SC-03).
func (s *sandbox) offline() error {
	if err := quitApp(); err != nil {
		return err
	}
	start := time.Now()
	res, err := s.m.call("files_find", map[string]any{"path": "~"})
	took := time.Since(start)
	if oerr := openApp(); oerr != nil {
		return errors.Join(err, oerr)
	}
	if err != nil {
		return err
	}
	if !strings.Contains(strings.ToLower(e2erelay.TextOf(res)), "offline") || took > 5*time.Second {
		return fmt.Errorf("with Latchkey quit: %q in %s, want the offline answer within 5 s", short(e2erelay.TextOf(res)), took.Round(time.Millisecond))
	}
	back, err := s.waitOnline()
	if err != nil {
		return err
	}
	step("the offline answer came in %s; started again, the Mac was back in %s", took.Round(time.Millisecond), back.Round(100*time.Millisecond))
	return nil
}

// relayRestart: the Mac comes back by itself after its relay restarts.
func (s *sandbox) relayRestart() error {
	s.relay.Close()
	time.Sleep(2 * time.Second)
	var err error
	if s.relay, err = startStateRelayAt(s.ctx, s.dir, sandboxRelayListen); err != nil {
		return err
	}
	back, err := s.waitOnline()
	if err != nil {
		return fmt.Errorf("after the relay restarted: %w", err)
	}
	step("the relay restarted; the Mac reconnected by itself in %s", back.Round(100*time.Millisecond))
	return s.connect()
}

// networkCut: a network that vanishes without closing anything is noticed (spec 001 SC-04:
// within 45 s), and the Mac reconnects once it returns.
func (s *sandbox) networkCut() error {
	s.px.blackhole()
	start := time.Now()
	if !waitFor(60*time.Second, func() bool { return !s.online() }) {
		s.px.restore()
		return errors.New("the relay never noticed the Mac was gone")
	}
	gone := time.Since(start)
	s.px.restore()
	if gone > 45*time.Second {
		return fmt.Errorf("offline noticed after %s; SC-04 allows 45 s", gone.Round(time.Second))
	}
	// No network change reaches the copy (only the proxy cut), so the app's own retry brings it
	// back; spec 001 SC-05's 10 s after a network change can't apply here.
	back, err := s.waitOnline()
	if err != nil {
		return fmt.Errorf("after the network returned: %w", err)
	}
	step("cut silently: offline noticed in %s; restored: reconnected in %s", gone.Round(time.Second), back.Round(100*time.Millisecond))
	return s.connect()
}

// suspended: an account the relay's operator suspends is disconnected and refused, keeps its
// pairing, and connects again once the suspension is lifted (spec 001 FR-204).
func (s *sandbox) suspended() error {
	d, err := s.relay.NewestDevice(s.ctx, ownerEmail)
	if err != nil {
		return err
	}
	if _, _, err := s.relay.DB.SuspendUser(s.ctx, ownerEmail, "sandbox check", "e2e-sandbox", time.Now()); err != nil {
		return err
	}
	lifted := false
	lift := func() error {
		if lifted {
			return nil
		}
		lifted = true
		_, _, err := s.relay.DB.UnsuspendUser(s.ctx, ownerEmail, "e2e-sandbox", time.Now())
		return err
	}
	defer func() { _ = lift() }()
	s.relay.Server.Hub.Suspend(d)
	if !waitFor(10*time.Second, func() bool { return !s.online() }) {
		return errors.New("the suspended account's Mac stayed connected")
	}
	time.Sleep(3 * time.Second)
	if s.online() {
		return errors.New("a suspended account's Mac connected")
	}
	dev, err := s.relay.DB.Device(s.ctx, d)
	if err != nil {
		return err
	}
	if !dev.RevokedAt.IsZero() {
		return errors.New("the suspension revoked the Mac's pairing")
	}
	if err := lift(); err != nil {
		return err
	}
	// A suspended Mac tries again every 5 minutes, or at once on a wake or network change; a
	// restart is the try here (the 5-minute retry isn't waited for).
	if err := quitApp(); err != nil {
		return err
	}
	if err := openApp(); err != nil {
		return err
	}
	back, err := s.waitOnline()
	if err != nil {
		return fmt.Errorf("after the suspension was lifted and Latchkey started again: %w", err)
	}
	step("suspended: disconnected and kept its pairing; lifted: connected again %s after a restart", back.Round(100*time.Millisecond))
	return nil
}

// battery: the state line every answer carries ("· N% battery") reads the real power source:
// within 1 of pmset's percent, or, with no battery (a virtual Mac), no made-up percent.
func (s *sandbox) battery() error {
	t, err := s.m.text("shell_run", map[string]any{"command": "echo battery-check"})
	if err != nil {
		return err
	}
	out, _ := exec.CommandContext(s.ctx, "/usr/bin/pmset", "-g", "batt").Output() //nolint:gosec // fixed program
	if why := batteryMismatch(t, string(out)); why != "" {
		return errors.New(why)
	}
	step("the state line's battery agrees with pmset")
	return nil
}

var (
	stateBatteryRE = regexp.MustCompile(`(\d+)% battery`)
	pmsetPercentRE = regexp.MustCompile(`(\d+)%`)
)

// batteryMismatch compares an answer's state line with `pmset -g batt`; "" when they agree.
func batteryMismatch(answer, pmset string) string {
	said, real := -1, -1
	if g := stateBatteryRE.FindStringSubmatch(answer); g != nil {
		said = atoi(g[1])
	}
	if g := pmsetPercentRE.FindStringSubmatch(pmset); g != nil {
		real = atoi(g[1])
	}
	switch {
	case real < 0 && said > 0:
		return fmt.Sprintf("no battery (pmset: %q), but the state line says %d%%", short(pmset), said)
	case real >= 0 && said < 0:
		return fmt.Sprintf("pmset says %d%%, the state line has no battery: %q", real, short(answer))
	case real >= 0 && (said < real-1 || said > real+1):
		return fmt.Sprintf("the state line says %d%%, pmset says %d%%", said, real)
	}
	return ""
}

func atoi(s string) int {
	n, _ := strconv.Atoi(s) // only ever digits, from the regular expressions above
	return n
}

// quitApp quits Latchkey in the copy and waits until it is gone.
func quitApp() error {
	_ = runQuiet("/usr/bin/osascript", "-e", `tell application id "`+sandboxAppID+`" to quit`)
	if waitFor(15*time.Second, func() bool { return runQuiet("/usr/bin/pgrep", "-x", "Latchkey") != nil }) {
		return nil
	}
	_ = runQuiet("/usr/bin/pkill", "-x", "Latchkey")
	if waitFor(5*time.Second, func() bool { return runQuiet("/usr/bin/pgrep", "-x", "Latchkey") != nil }) {
		return nil
	}
	return errors.New("latchkey didn't quit")
}

func openApp() error { return runQuiet("/usr/bin/open", "-a", sandboxAppPath) }

func runQuiet(name string, args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput() //nolint:gosec // fixed programs
	if err != nil {
		return fmt.Errorf("%s %s: %w: %s", filepath.Base(name), strings.Join(args, " "), err, short(string(out)))
	}
	return nil
}

// cutProxy forwards TCP from listen to target and can drop traffic silently, like a network that
// vanished without closing connections (cmd/maccheck's proxy; here a side that closes closes
// the other too, so a relay that restarts is seen at once).
type cutProxy struct {
	l      net.Listener
	target string

	mu     sync.Mutex
	paused bool
	conns  []net.Conn
}

func newCutProxy(ctx context.Context, listen, target string) (*cutProxy, error) {
	l, err := (&net.ListenConfig{}).Listen(ctx, "tcp", listen)
	if err != nil {
		return nil, err
	}
	p := &cutProxy{l: l, target: target}
	go p.accept(ctx)
	return p, nil
}

func (p *cutProxy) addr() string { return p.l.Addr().String() }

func (p *cutProxy) accept(ctx context.Context) {
	for {
		c, err := p.l.Accept()
		if err != nil {
			return
		}
		p.mu.Lock()
		p.conns = append(p.conns, c)
		paused := p.paused
		p.mu.Unlock()
		if paused {
			continue // swallowed: never answered
		}
		up, err := (&net.Dialer{}).DialContext(ctx, "tcp", p.target)
		if err != nil {
			_ = c.Close()
			continue
		}
		p.mu.Lock()
		p.conns = append(p.conns, up)
		p.mu.Unlock()
		go p.pipe(up, c)
		go p.pipe(c, up)
	}
}

func (p *cutProxy) pipe(dst, src net.Conn) {
	defer func() { _ = dst.Close(); _ = src.Close() }()
	buf := make([]byte, 32<<10)
	for {
		n, err := src.Read(buf)
		if err != nil {
			return
		}
		p.mu.Lock()
		paused := p.paused
		p.mu.Unlock()
		if paused {
			continue // dropped on the floor
		}
		if _, err := dst.Write(buf[:n]); err != nil {
			return
		}
	}
}

func (p *cutProxy) blackhole() {
	p.mu.Lock()
	p.paused = true
	p.mu.Unlock()
}

// restore closes every connection from before (they died with the network) and forwards again.
func (p *cutProxy) restore() {
	p.mu.Lock()
	for _, c := range p.conns {
		_ = c.Close()
	}
	p.conns = nil
	p.paused = false
	p.mu.Unlock()
}

func (p *cutProxy) close() {
	_ = p.l.Close()
	p.restore()
}

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/e2erelay"
	"github.com/tonimelisma/latchkey/relay/internal/intake"
	"github.com/tonimelisma/latchkey/relay/internal/mcpserver"
	"github.com/tonimelisma/latchkey/relay/internal/trace"
	"github.com/tonimelisma/latchkey/relay/reports"
)

// The checks relay/e2e/sandbox-checks.md listed as not written until spec 016 T19 (2026-11-27):
// the Safari tab a script sends away and a busy tab, setup naming an app turned off, a Finder
// sidebar row pressed and a window's buttons named, a problem report from the installed app,
// headless Chrome's profile, and keep-awake.

// skipCheck is a check that can't run in this copy, with the reason; it is reported as skipped.
type skipCheck struct{ why string }

func (s skipCheck) Error() string { return s.why }

// safariScriptNavigation: a script of Claude's that sends its Safari tab to another site loses
// the tab, as designed (a script never opens the allowance to follow a tab: security review,
// fourth round, 2026-10-29): Latchkey no longer uses the tab and has forgotten it.
func (s *sandbox) safariScriptNavigation() error {
	p, err := startWebPages(s.ctx, s.m.marker)
	if err != nil {
		return err
	}
	defer p.close()
	defer closeSafariTabs(p)
	t, err := s.ask("browser_look", map[string]any{"url": p.site() + "/", "show_in_safari": true}, "Actions marker "+s.m.marker)
	if err != nil {
		return err
	}
	pg := pageName(t)
	if pg == "" {
		return fmt.Errorf("show_in_safari gave the page no name: %q", short(t))
	}
	if _, err := s.script(map[string]any{"page": pg}, "location.href = '"+p.other()+"/other'; 'sent'"); err != nil {
		return fmt.Errorf("the script that sends the tab away: %w", err)
	}
	if !waitFor(15*time.Second, func() bool { return p.saw("/other") }) {
		return errors.New("the script's navigation never reached the other site")
	}
	var answer string
	if !waitFor(15*time.Second, func() bool {
		res, err := s.m.call("browser_look", map[string]any{"page": pg})
		if err != nil {
			return false
		}
		answer = e2erelay.TextOf(res)
		return res.IsError
	}) {
		return fmt.Errorf("after the script sent it to another site, Latchkey still reads the tab: %q", short(answer))
	}
	tabs, err := s.ask("browser_look", map[string]any{"tabs": true})
	if err != nil {
		return err
	}
	if strings.Contains(tabs, `"`+pg+`"`) {
		return fmt.Errorf("the tab the script sent away is still listed as Claude's %q: %q", pg, short(tabs))
	}
	step("safari: a script that sent Claude's tab to another site lost the tab (%q), and the tab list no longer names it", short(answer))
	return nil
}

// closeSafariTabs closes every Safari tab on the check's two sites (a tab Latchkey no longer
// knows isn't closed by Latchkey).
func closeSafariTabs(p *webPages) {
	_ = osa(`on run argv
tell application "Safari"
repeat with w in windows
repeat with t in (tabs of w)
if (URL of t) starts with (item 1 of argv) or (URL of t) starts with (item 2 of argv) then close t
end repeat
end repeat
end tell
end run`, p.site(), p.other())
}

// safariBusyTab: an owner's tab whose page keeps Safari's script for it busy (the former case
// browser_busy_tab_not_called_dialog: real Safari answered a tab's first script 12 s late, and
// Latchkey called it a dialog) is said to be busy first, a dialog only maybe, within the tab
// check's 10 s, and Claude's call still answers in time.
func (s *sandbox) safariBusyTab() error {
	p, err := startWebPages(s.ctx, s.m.marker)
	if err != nil {
		return err
	}
	defer p.close()
	defer closeSafariTabs(p)
	if err := runQuiet("/usr/bin/open", "-g", "-a", "Safari", p.site()+"/busy"); err != nil {
		return err
	}
	var ref string
	if !waitFor(30*time.Second, func() bool {
		t, err := s.m.text("browser_look", map[string]any{"tabs": true})
		if err != nil {
			return false
		}
		for line := range strings.SplitSeq(t, "\n") {
			if strings.Contains(line, "Busy page") || strings.Contains(line, "/busy") {
				ref = tabRefRE.FindString(line)
			}
		}
		return ref != ""
	}) {
		return errors.New("the busy tab isn't in the tab list")
	}
	if !waitFor(20*time.Second, func() bool { return p.saw("/busy-started") }) {
		return errors.New("the busy page never started keeping its script busy")
	}
	start := time.Now()
	res, err := s.m.call("browser_look", map[string]any{"tab": ref})
	took := time.Since(start)
	if err != nil {
		return err
	}
	t := e2erelay.TextOf(res)
	low := strings.ToLower(t)
	busy, dialog := strings.Index(low, "busy"), strings.Index(low, "dialog")
	switch {
	case !res.IsError:
		return fmt.Errorf("the busy tab was read as if it answered (in %s): %q", took.Round(time.Second), short(t))
	case !strings.Contains(t, "didn't answer within 10 seconds"):
		return fmt.Errorf("the busy tab's answer doesn't say it didn't answer within 10 seconds: %q", short(t))
	case busy < 0 || (dialog >= 0 && dialog < busy):
		return fmt.Errorf("the busy tab isn't said to be busy before a dialog is named: %q", short(t))
	case took >= 30*time.Second:
		return fmt.Errorf("the answer about the busy tab took %s, past the relay's 30 s (Constitution II)", took.Round(time.Second))
	}
	step("safari: a tab whose script stayed busy was said busy first, a dialog only maybe, in %s", took.Round(100*time.Millisecond))
	return nil
}

// finderWindow opens a Finder window on Documents in the background (the copy's front is
// Finder's empty desktop) and returns its closer.
func finderWindow() (func(), error) {
	if err := osa(`tell application "Finder" to make new Finder window to (path to documents folder)`); err != nil {
		return nil, err
	}
	return func() { _ = osa(`tell application "Finder" to close every Finder window`) }, nil
}

// computerWindowButtons: a window's untitled buttons are named by kind (the former case
// computer_window_buttons_named: 2026-11-20 they were listed with empty names, so the close
// button had to be guessed).
func (s *sandbox) computerWindowButtons() error {
	closeWindow, err := finderWindow()
	if err != nil {
		return err
	}
	defer closeWindow()
	var t string
	if !waitFor(10*time.Second, func() bool {
		t, err = s.m.text("computer_look", map[string]any{"show": "ui", "app": "Finder"})
		return err == nil && strings.Contains(t, "close button")
	}) {
		return fmt.Errorf("finder's window has no element named \"close button\": %q (%w)", short(t), err)
	}
	for _, kind := range []string{"close button", "minimize button"} {
		if refFor(t, kind) == "" {
			return fmt.Errorf("finder's window lists no %q with a reference: %q", kind, short(t))
		}
	}
	// The green button is named by kind too, or by its own help ("this button also has an action
	// to zoom the window", macOS 26): named either way, never "".
	if refFor(t, "zoom button") == "" && refFor(t, "full screen button") == "" && refFor(t, "to zoom the window") == "" {
		return fmt.Errorf("finder's window names neither a zoom nor a full screen button: %q", short(t))
	}
	step("computer: Finder's window buttons are named (close, minimize, and the zoom button)")
	return nil
}

// computerSidebarRow: a press on a row of Finder's sidebar (or its cell or text) selects the row
// (the former case computer_press_selects_sidebar_row; Toni, 2026-11-23: "press selects the row"),
// as macOS's own Accessibility reads the sidebar (the test Mac's osascript may read it: its image
// script). Finder opens a folder only on a click, so the window still shows Documents (seen
// 2026-11-27): that the press also opens is a choice for Toni, not this check.
func (s *sandbox) computerSidebarRow() error {
	closeWindow, err := finderWindow()
	if err != nil {
		return err
	}
	defer closeWindow()
	selected := func() string {
		out, _ := osaOut(`tell application "System Events" to tell process "Finder"
repeat with r in rows of outline 1 of scroll area 1 of splitter group 1 of front window
try
if selected of r then return value of static text 1 of UI element 1 of r
end try
end repeat
return ""
end tell`)
		return out
	}
	if !waitFor(10*time.Second, func() bool { return selected() == "Documents" }) {
		return fmt.Errorf("the check's Finder window has %q selected in its sidebar, not Documents (can the test Mac's osascript read it?)", selected())
	}
	var t string
	if !waitFor(10*time.Second, func() bool {
		t, err = s.m.text("computer_look", map[string]any{"show": "ui", "app": "Finder", "match": "Downloads"})
		return err == nil && refFor(t, "Downloads") != ""
	}) {
		return fmt.Errorf("computer_look finds no Downloads in Finder's window: %q (%w)", short(t), err)
	}
	ref := refFor(t, "Downloads")
	r, err := s.ask("computer_act", map[string]any{"action": "press", "app": "Finder", "ref": ref}, "Pressed")
	if err != nil && strings.Contains(err.Error(), "look again") {
		// Finder's window had just opened in a fresh copy (2026-11-27): the answer says to look
		// again, and Claude would; so does the check, once.
		time.Sleep(2 * time.Second)
		if t, err = s.m.text("computer_look", map[string]any{"show": "ui", "app": "Finder", "match": "Downloads"}); err != nil {
			return err
		}
		ref = refFor(t, "Downloads")
		r, err = s.ask("computer_act", map[string]any{"action": "press", "app": "Finder", "ref": ref}, "Pressed")
	}
	if err != nil {
		return err
	}
	if !waitFor(10*time.Second, func() bool { return selected() == "Downloads" }) {
		return fmt.Errorf("after the press (%q), Finder's sidebar has %q selected, not Downloads", short(r), selected())
	}
	step("computer: a press on the text of Finder's Downloads row (%s) selected the row", ref)
	return nil
}

// headlessChromeProfile: headless Chrome's print-to-PDF works through shell_run with its profile
// in the scratch folder (2026-11-24, 0.8.240: without it Chrome exited 0 and wrote no file, the
// fence keeping it out of macOS's temporary folder), and shell_run's description says so.
func (s *sandbox) headlessChromeProfile() error {
	const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
	if _, err := os.Stat(chrome); err != nil {
		return skipCheck{"the image has no Google Chrome"}
	}
	tools, err := e2erelay.ListAllTools(s.ctx, s.cs)
	if err != nil {
		return err
	}
	desc := ""
	for _, t := range tools {
		if t.Name == "shell_run" {
			desc = t.Description
		}
	}
	if !strings.Contains(desc, "--user-data-dir") {
		return fmt.Errorf("shell_run's description doesn't say headless Chrome needs --user-data-dir: %q", short(desc))
	}
	cmd := `"` + chrome + `" --headless=new --no-sandbox --user-data-dir="$LATCHKEY_SCRATCH/chr" --print-to-pdf="$LATCHKEY_SCRATCH/x.pdf" about:blank >/dev/null 2>&1; ls -l "$LATCHKEY_SCRATCH/x.pdf" && head -c 5 "$LATCHKEY_SCRATCH/x.pdf"`
	t, err := s.ask("shell_run", map[string]any{"command": cmd, "uses": []any{"open"}}, "x.pdf", "%PDF-")
	if err != nil {
		return err
	}
	step("shell: headless Chrome printed a PDF with its profile in the scratch folder (%s)", short(strings.SplitN(t, "\n", 2)[0]))
	return nil
}

// keepAwakeReal: with keep-awake on, macOS's SleepDisabled is 1 (the former case
// machines_keep_awake_real: from 2026-10-25 until 0.8.19 the helper refused every app connection
// and the laptop slept). The helper runs only for an app signed by an Apple team (it checks its
// caller's signature, .claude/rules/macos.md): the sandbox's self-signed build has none, so macOS
// refuses to register it and keep-awake stays off; then the check says so and is skipped.
func (s *sandbox) keepAwakeReal() error {
	t, err := s.m.text("machines", map[string]any{})
	if err != nil {
		return err
	}
	low := strings.ToLower(t)
	out, _ := exec.CommandContext(s.ctx, "/usr/bin/pmset", "-g").Output() //nolint:gosec // fixed program
	disabled := regexp.MustCompile(`(?m)^\s*SleepDisabled\s+(\d)`).FindStringSubmatch(string(out))
	switch {
	case strings.Contains(low, "keep-awake on"):
		if disabled == nil || disabled[1] != "1" {
			return fmt.Errorf("keep-awake is on, but pmset says SleepDisabled %v", disabled)
		}
		step("keep-awake on, and SleepDisabled is 1")
		return nil
	case strings.Contains(low, "keep-awake off (not approved"):
		return skipCheck{"the sandbox build is self-signed (no Apple team), so macOS refuses its keep-awake helper " +
			"(\"keep-awake off (not approved in System Settings)\"); the check needs a build signed by an Apple team " +
			"in the image (CI's Apple Development identity, or the paid Developer Program's Developer ID)"}
	case strings.Contains(low, "keep-awake off"):
		return fmt.Errorf("keep-awake is off and the state line doesn't say why: %q", short(t))
	}
	return fmt.Errorf("the machines answer doesn't say whether keep-awake is on: %q", short(t))
}

// setupNamesWhatIsOff: with an app's control turned off for Latchkey earlier (which macOS never
// asks about again), setup's Ask Now says so and opens the place to turn it on (the former case
// setup_ask_now_says_what_is_off; Toni, 2026-11-21: Ask Now spun a second and did nothing). Mail's
// control is turned off in the copy's permission database (root, System Integrity Protection off
// there), setup's Ask Now pressed with Return in the test Mac (System Events; Latchkey's own
// computer control never acts on Latchkey's windows), and everything put back after.
func (s *sandbox) setupNamesWhatIsOff() error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	db := filepath.Join(home, "Library", "Application Support", "com.apple.TCC", "TCC.db")
	mailControl := func(allowed bool) error {
		v := "0"
		if allowed {
			v = "2"
		}
		q := "UPDATE access SET auth_value=" + v + " WHERE service='kTCCServiceAppleEvents' AND client='" +
			sandboxAppID + "' AND indirect_object_identifier='com.apple.mail';"
		if err := runQuiet("/usr/bin/sudo", "-n", "/usr/bin/sqlite3", db, q); err != nil {
			return fmt.Errorf("changing Latchkey's control of Mail in the permission database: %w", err)
		}
		_ = runQuiet("/usr/bin/sudo", "-n", "/usr/bin/killall", "tccd")
		return nil
	}
	if err := quitApp(); err != nil {
		return err
	}
	defer func() {
		_ = osa(`tell application "System Settings" to quit`)
		_ = mailControl(true)
		_ = quitApp()
		_ = openApp()
		_, _ = s.waitOnline()
	}()
	if err := mailControl(false); err != nil {
		return err
	}
	if err := openApp(); err != nil {
		return err
	}
	if _, err := s.waitOnline(); err != nil {
		return err
	}
	// Setup opens by itself (Mail's control is missing); Ask Now is its default button, so
	// Return presses it, as a person at the Mac would.
	if !waitFor(30*time.Second, func() bool {
		n, err := osaOut(`tell application "System Events" to return (count of windows of process "Latchkey") as text`)
		return err == nil && n != "0"
	}) {
		return errors.New("setup didn't open with Mail's control turned off")
	}
	if err := osa(`tell application "System Events" to tell process "Latchkey"
set frontmost to true
delay 1
keystroke return
end tell`); err != nil {
		return fmt.Errorf("pressing Return in setup: %w", err)
	}
	const said = "Allow All: turned off earlier, so not asked: Mail; opened Automation settings"
	var log string
	if !waitFor(90*time.Second, func() bool {
		log, err = s.m.text("latchkey_log", map[string]any{"category": "permissions", "lines": 200})
		return err == nil && strings.Contains(log, said)
	}) {
		return fmt.Errorf("after Ask Now, Latchkey's log never said %q: %q", said, short(tail(log, 1500)))
	}
	var note string
	if !waitFor(10*time.Second, func() bool {
		note, err = osaOut(latchkeyTextScript, "turned off for Latchkey earlier")
		return err == nil && strings.Contains(note, "Mail was turned off for Latchkey earlier")
	}) {
		return fmt.Errorf("setup's note doesn't name Mail as turned off: %q (%w)", note, err)
	}
	step("setup: with Mail's control turned off, Ask Now said so, named where to turn it on, and opened Automation settings")
	return nil
}

// latchkeyTextScript answers the text in Latchkey's windows that holds item 1 of argv, or "".
const latchkeyTextScript = `on find(e, wanted, depth)
if depth > 20 then return ""
tell application "System Events"
try
if role of e is "AXStaticText" then
set v to (value of e) as text
if v contains wanted then return v
end if
end try
repeat with k in (UI elements of e)
set f to my find(k, wanted, depth + 1)
if f is not "" then return f
end repeat
end tell
return ""
end find
on run argv
tell application "System Events"
if not (exists process "Latchkey") then return ""
repeat with w in (windows of process "Latchkey")
set f to my find(w, item 1 of argv, 0)
if f is not "" then return f
end repeat
end tell
return ""
end run`

// reportFromInstalledApp: with sharing on, a problem report from the installed app holds the
// chat's calls and pages, with what Claude typed into a password field blanked everywhere and
// no machine name (the former case regressions.report_holds_the_chats_pages; spec 014 FR-1440 to
// FR-1449). The relay restarts with a throwaway intake and developer key inside the copy; the
// report is read with that key and deleted; sharing and the relay are put back after.
func (s *sandbox) reportFromInstalledApp() error {
	work, err := os.MkdirTemp("", "latchkey-report-check-")
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(work) }()
	pub, priv, err := reports.GenerateKey()
	if err != nil {
		return err
	}
	pk, err := reports.PublicKey(pub)
	if err != nil {
		return err
	}
	const devToken = "sandbox-developer-token-for-the-report-check" // the intake wants 32 characters or more
	in, err := intake.Open(filepath.Join(work, "intake.db"), intake.Options{DeveloperToken: devToken, WorkBits: 8})
	if err != nil {
		return err
	}
	defer func() { _ = in.Close() }()
	l, err := (&net.ListenConfig{}).Listen(s.ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	isrv := &http.Server{Handler: in.Handler(), ReadHeaderTimeout: 10 * time.Second}
	go func() { _ = isrv.Serve(l) }()
	defer func() { _ = isrv.Close() }()
	intakeURL := "http://" + l.Addr().String()
	ts, err := trace.New(trace.Options{Dir: filepath.Join(work, "traces"), Key: bytes.Repeat([]byte{7}, 32)})
	if err != nil {
		return err
	}
	// The relay with the intake, and Latchkey sharing reports; both put back after.
	restart := func(o mcpserver.ReportsOptions, tr *trace.Store) error {
		s.relay.Close()
		time.Sleep(time.Second)
		var err error
		if s.relay, err = e2erelay.StartPrivate(s.ctx, e2erelay.PrivateOptions{
			DBPath: filepath.Join(s.dir, "relay.db"), Listen: sandboxRelayListen, PublicURL: relayURL,
			CertFile: filepath.Join(s.dir, "relay.pem"), KeyFile: filepath.Join(s.dir, "relay-key.pem"),
			Reports: o, Traces: tr,
		}); err != nil {
			return err
		}
		if _, err := s.waitOnline(); err != nil {
			return err
		}
		return s.connect()
	}
	sendCtx, stopSending := context.WithCancel(s.ctx)
	defer stopSending()
	if err := restart(mcpserver.ReportsOptions{IntakeURL: intakeURL, DeveloperKey: pk, WorkBits: 8}, ts); err != nil {
		return err
	}
	go s.relay.Server.SendReports(sendCtx)
	defer func() {
		stopSending()
		_ = quitApp()
		_ = runQuiet("/usr/bin/defaults", "delete", sandboxAppID, "shareProblemReports")
		_ = openApp()
		_ = restart(mcpserver.ReportsOptions{}, nil)
	}()
	if err := quitApp(); err != nil {
		return err
	}
	if err := runQuiet("/usr/bin/defaults", "write", sandboxAppID, "shareProblemReports", "-bool", "true"); err != nil {
		return err
	}
	if err := openApp(); err != nil {
		return err
	}
	if _, err := s.waitOnline(); err != nil {
		return err
	}
	if !waitFor(30*time.Second, func() bool {
		tools, err := e2erelay.ListAllTools(s.ctx, s.cs)
		return err == nil && contains(toolNames(tools), "feedback")
	}) {
		return errors.New("with sharing on, the relay never offered the feedback tool")
	}
	p, err := startWebPages(s.ctx, s.m.marker)
	if err != nil {
		return err
	}
	defer p.close()
	t, err := s.ask("browser_look", map[string]any{"url": p.site() + "/signin"}, "Sign-in page marker "+s.m.marker)
	if err != nil {
		return err
	}
	pg := pageName(t)
	pw := refFor(t, "Password")
	if pg == "" || pw == "" {
		return fmt.Errorf("the sign-in page has no name or no password field: %q", short(t))
	}
	defer func() { _, _ = s.m.text("browser_act", map[string]any{"action": "close", "page": pg}) }()
	secret := "pw" + s.m.marker + "Zq9"
	if _, err := s.act(map[string]any{"page": pg}, map[string]any{"action": "type", "ref": pw, "text": secret}); err != nil {
		return err
	}
	if _, err := s.ask("feedback", map[string]any{
		"summary": s.tag() + " report check", "details": "check of the report's contents",
		"machines": []any{s.m.machine},
	}, "queued"); err != nil {
		return err
	}
	var plain []byte
	if !waitFor(60*time.Second, func() bool {
		plain, err = fetchReport(intakeURL, devToken, priv)
		return err == nil && plain != nil
	}) {
		return fmt.Errorf("the report never reached the check's intake: %w", err)
	}
	text := string(plain)
	for _, want := range []string{"browser_look", pg, "Sign-in page marker " + s.m.marker, s.tag() + " report check"} {
		if !strings.Contains(text, want) {
			return fmt.Errorf("the report lacks %q (%d bytes)", want, len(plain))
		}
	}
	for _, never := range []string{secret, s.m.machine} {
		if strings.Contains(text, never) {
			return fmt.Errorf("the report holds %q, which must be blanked", never)
		}
	}
	step("report: the installed app's report held the chat's calls and its page, with the typed password and the machine's name left out (%d bytes)", len(plain))
	return nil
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// fetchReport reads the first waiting report from the check's intake, opens it with the check's
// key and deletes it; nil when none is waiting yet.
func fetchReport(base, token, priv string) ([]byte, error) {
	get := func(method, path string) ([]byte, error) {
		req, err := http.NewRequest(method, base+path, nil) //nolint:noctx // a check's own local intake
		if err != nil {
			return nil, err
		}
		req.Header.Set("Authorization", "Bearer "+token)
		resp, err := http.DefaultClient.Do(req) //nolint:gosec // the check's own intake on 127.0.0.1
		if err != nil {
			return nil, err
		}
		defer func() { _ = resp.Body.Close() }()
		b, err := io.ReadAll(resp.Body)
		if resp.StatusCode >= 300 {
			return nil, fmt.Errorf("the intake answered %d to %s %s", resp.StatusCode, method, path)
		}
		return b, err
	}
	b, err := get(http.MethodGet, "/v1/reports")
	if err != nil {
		return nil, err
	}
	var listed []intake.Listed
	if err := json.Unmarshal(b, &listed); err != nil {
		return nil, err
	}
	if len(listed) == 0 {
		return nil, nil
	}
	sealed, err := get(http.MethodGet, "/v1/reports/"+listed[0].ID)
	if err != nil {
		return nil, err
	}
	_, _ = get(http.MethodDelete, "/v1/reports/"+listed[0].ID)
	k, err := reports.PrivateKey(priv)
	if err != nil {
		return nil, err
	}
	return reports.OpenRaw(k, sealed)
}

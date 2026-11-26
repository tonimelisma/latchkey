package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/tonimelisma/latchkey/relay/internal/e2erelay"
)

// The web checks of the sandbox copy (relay/e2e/sandbox-checks.md): Latchkey's own browser (the
// former state-check browser group) and the copy's real Safari (the former safari-check), on
// pages served inside the copy. The same server answers at 127.0.0.1 and at localhost, which a
// browser counts as two sites.

type webPages struct {
	port int
	srv  *http.Server
	mu   sync.Mutex
	got  []string
}

func (p *webPages) site() string  { return "http://127.0.0.1:" + strconv.Itoa(p.port) }
func (p *webPages) other() string { return "http://localhost:" + strconv.Itoa(p.port) }

func (p *webPages) saw(uri string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return slices.Contains(p.got, uri)
}

func (p *webPages) close() { _ = p.srv.Close() }

// webActionsPage is every action Claude can take on a page (was safari-check's actions.html).
const webActionsPage = `<!doctype html><html><head><meta charset="utf-8"><title>Latchkey check actions</title>
<style>#submenu{display:none} #box{height:80px;overflow:auto;border:1px solid #888} #box div{height:900px} #tall{height:3000px}</style></head>
<body><h1>Actions marker %[1]s</h1>
<p><a href="/next">Next page</a> <a href="%[2]s/other">Other site</a></p>
<form id="form" onsubmit="document.title='sent:'+document.getElementById('name').value; return false;">
<input id="name" name="name" aria-label="Your name" placeholder="Your name"></form>
<form action="/search" method="get"><input name="q" aria-label="Search words" placeholder="Search words"></form>
<p id="keys">keys:</p><div id="panel">An open panel</div>
<select id="size" aria-label="Size"><option value="s">Small</option><option value="m">Medium</option><option value="l">Large</option></select>
<div id="menu" aria-haspopup="true" onmouseenter="document.getElementById('submenu').style.display='block'">Products menu</div>
<div id="submenu"><a href="#sub">Hidden product</a></div>
<div id="box" aria-label="Latchkey box"><div>Inside the scrolling box</div></div>
<label>Attach <input id="file" type="file" aria-label="Attach"></label><p id="filelog">files:</p>
<a id="dl" href="/statement.txt" download>Save the statement</a>
<a id="pdf" href="/report.pdf">The PDF</a>
<button onclick="setTimeout(function(){document.title='asked:'+confirm('Latchkey check: remove item?')},300)">Remove item</button>
<div id="tall">Long part of the page</div><p id="end">The end</p>
<script>
document.addEventListener('keydown',function(e){document.getElementById('keys').textContent+=' '+e.key; if(e.key==='Escape'){var d=document.getElementById('panel'); if(d) d.remove();}});
document.getElementById('file').addEventListener('change',function(e){var l=document.getElementById('filelog'); Array.prototype.forEach.call(e.target.files,function(f){l.textContent+=' '+f.name+'='+f.size;});});
</script></body></html>`

func startWebPages(ctx context.Context, marker string) (*webPages, error) {
	l, err := (&net.ListenConfig{}).Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	p := &webPages{port: l.Addr().(*net.TCPAddr).Port}
	page := func(body string) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = fmt.Fprint(w, body)
		}
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/{$}", page(fmt.Sprintf(webActionsPage, marker, p.other())))
	mux.HandleFunc("/next", page(`<!doctype html><title>Next</title><h1>Next page marker `+marker+`</h1><a href="/">Home</a>`))
	mux.HandleFunc("/other", page(`<!doctype html><title>Other</title><h1>Other site marker `+marker+`</h1><a href="/next">Onwards</a>`))
	mux.HandleFunc("/owner", page(`<!doctype html><title>Owner page</title><h1>Owner page marker `+marker+`</h1><a href="/next">Owner link</a>`))
	mux.HandleFunc("/search", page(`<!doctype html><title>Results</title><p>Results</p>`))
	mux.HandleFunc("/long", page(`<!doctype html><title>Long</title><p>`+strings.Repeat("Long page words. ", 12000)+`</p><p>Last words `+marker+`</p>`))
	mux.HandleFunc("/statement.txt", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Content-Disposition", `attachment; filename="latchkey-check-statement.txt"`)
		_, _ = fmt.Fprintf(w, "%s marker statement %s\n", evalName, marker)
	})
	mux.HandleFunc("/report.pdf", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/pdf")
		_, _ = w.Write(testPDF(evalName + " marker report " + marker))
	})
	logged := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p.mu.Lock()
		p.got = append(p.got, r.URL.RequestURI())
		p.mu.Unlock()
		mux.ServeHTTP(w, r)
	})
	p.srv = &http.Server{Handler: logged, ReadHeaderTimeout: 10 * time.Second}
	go func() { _ = p.srv.Serve(l) }()
	return p, nil
}

var tabRefRE = regexp.MustCompile(`\b(\d+\.\d+)\b`)

// pageName is the name an answer gives Claude's page.
func pageName(t string) string {
	if g := pageRE.FindStringSubmatch(t); g != nil {
		return g[1]
	}
	return ""
}

// onPage runs browser_act on Claude's page (or, with tab, on one of the owner's tabs).
func (s *sandbox) act(where map[string]any, args map[string]any, want ...string) (string, error) {
	a := map[string]any{}
	for k, v := range where {
		a[k] = v
	}
	for k, v := range args {
		a[k] = v
	}
	return s.ask("browser_act", a, want...)
}

func (s *sandbox) look(where map[string]any, args map[string]any, want ...string) (string, error) {
	a := map[string]any{}
	for k, v := range where {
		a[k] = v
	}
	for k, v := range args {
		a[k] = v
	}
	return s.ask("browser_look", a, want...)
}

// pageActions is the shared part of the own-browser and Safari checks: on the actions page,
// every action Claude can take, each seen on the page or the disk.
func (s *sandbox) pageActions(where map[string]any, home string, p *webPages) error {
	t, err := s.look(where, nil, "Actions marker "+s.m.marker)
	if err != nil {
		return err
	}
	name, search, size, menu, file := refFor(t, "Your name"), refFor(t, "Search words"), refFor(t, "Size"), refFor(t, "Products menu"), refFor(t, "Attach")
	if name == "" || search == "" || size == "" || menu == "" || file == "" {
		return fmt.Errorf("the actions page lacks a reference (name %q search %q size %q menu %q file %q): %q", name, search, size, menu, file, short(t))
	}
	// type and submit; keys; Escape
	if _, err := s.act(where, map[string]any{"action": "type", "ref": search, "text": "hello e2e", "submit": true}); err != nil {
		return err
	}
	if !waitFor(20*time.Second, func() bool { return p.saw("/search?q=hello+e2e") }) {
		return errors.New("the typed search never reached the served page")
	}
	if _, err := s.look(where, map[string]any{"back": true}, "Actions marker"); err != nil {
		return fmt.Errorf("back after the search: %w", err)
	}
	t, err = s.look(where, nil)
	if err != nil {
		return err
	}
	name, size, menu, file = refFor(t, "Your name"), refFor(t, "Size"), refFor(t, "Products menu"), refFor(t, "Attach")
	box := refFor(t, "Latchkey box")
	if _, err := s.act(where, map[string]any{"action": "type", "ref": name, "text": "hi"}); err != nil {
		return err
	}
	if _, err := s.act(where, map[string]any{"action": "key", "ref": name, "keys": []any{"Enter"}}); err != nil {
		return err
	}
	if v, err := s.script(where, "document.title"); err != nil || !strings.Contains(v, "sent:hi") {
		return fmt.Errorf("pressing Enter in the name field didn't send the form: title %q (%w)", v, err)
	}
	if _, err := s.act(where, map[string]any{"action": "key", "keys": []any{"Escape"}}); err != nil {
		return err
	}
	if v, err := s.script(where, "String(!document.getElementById('panel'))"); err != nil || !strings.Contains(v, "true") {
		return fmt.Errorf("the Escape key didn't reach the page (the panel is still there: %q, %w)", v, err)
	}
	// select, hover, scroll
	if _, err := s.act(where, map[string]any{"action": "select", "ref": size, "options": []any{"Large"}}); err != nil {
		return err
	}
	if v, err := s.script(where, "document.getElementById('size').value"); err != nil || !strings.Contains(v, "l") {
		return fmt.Errorf("select Large: the list holds %q (%w)", v, err)
	}
	if _, err := s.act(where, map[string]any{"action": "hover", "ref": menu}, "Hidden product"); err != nil {
		return fmt.Errorf("hover didn't show the menu: %w", err)
	}
	if _, err := s.act(where, map[string]any{"action": "scroll", "direction": "down", "amount": 500}); err != nil {
		return err
	}
	if v, err := s.script(where, "String(Math.round(window.scrollY))"); err != nil || atoi(strings.TrimSpace(firstNumber(v))) < 400 {
		return fmt.Errorf("after scrolling down 500 the page is at %q (%w)", v, err)
	}
	if box != "" {
		if _, err := s.act(where, map[string]any{"action": "scroll", "ref": box, "direction": "bottom"}); err != nil {
			return err
		}
		if v, err := s.script(where, "String(document.getElementById('box').scrollTop)"); err != nil || atoi(firstNumber(v)) < 500 {
			return fmt.Errorf("the box scrolled to its bottom is at %q (%w)", v, err)
		}
	}
	if _, err := s.act(where, map[string]any{"action": "scroll", "direction": "top"}); err != nil {
		return err
	}
	// a file in, a file and the PDF out
	up := filepath.Join(home, "Downloads", "latchkey-check-upload-"+s.m.marker+".txt")
	if err := os.WriteFile(up, []byte(evalName+" marker upload\n"), 0o600); err != nil {
		return err
	}
	defer func() { _ = os.Remove(up) }()
	if _, err := s.act(where, map[string]any{"action": "upload", "ref": file, "paths": []any{up}}); err != nil {
		return err
	}
	if v, err := s.script(where, "document.getElementById('filelog').textContent"); err != nil || !strings.Contains(v, filepath.Base(up)) {
		return fmt.Errorf("the page didn't get the uploaded file: %q (%w)", v, err)
	}
	since := time.Now().Add(-time.Second)
	t, err = s.act(where, map[string]any{"action": "download", "ref": refFor(t, "Save the statement")})
	if err != nil {
		return err
	}
	var saved string
	if !waitFor(30*time.Second, func() bool {
		saved = newestWith(filepath.Join(home, "Downloads"), since, "marker statement "+s.m.marker)
		return saved != ""
	}) {
		return fmt.Errorf("the link's file isn't in Downloads (answer %q)", short(t))
	}
	_ = os.Remove(saved)
	return nil
}

// script runs JavaScript in the page and returns the answer's text.
func (s *sandbox) script(where map[string]any, code string) (string, error) {
	return s.act(where, map[string]any{"action": "script", "code": code})
}

var numberRE = regexp.MustCompile(`-?\d+`)

func firstNumber(s string) string { return numberRE.FindString(s) }

// browserFull: Latchkey's own browser (former state-check browser.*), on served pages.
func (s *sandbox) browserFull() error {
	if err := s.m.browser(); err != nil {
		return err
	}
	p, err := startWebPages(s.ctx, s.m.marker)
	if err != nil {
		return err
	}
	defer p.close()
	home, _ := os.UserHomeDir()
	var opened []string
	defer func() {
		for _, pg := range opened {
			_, _ = s.m.text("browser_act", map[string]any{"action": "close", "page": pg})
		}
	}()
	t, err := s.ask("browser_look", map[string]any{"url": p.site() + "/"}, "Actions marker "+s.m.marker)
	if err != nil {
		return err
	}
	pg := pageName(t)
	if pg == "" {
		return fmt.Errorf("browser_look gave the page no name: %q", short(t))
	}
	opened = append(opened, pg)
	where := map[string]any{"page": pg}
	if _, err := s.act(where, map[string]any{"action": "click", "ref": refFor(t, "Next page")}, "Next page marker"); err != nil {
		return fmt.Errorf("a same-site link: %w", err)
	}
	if _, err := s.look(where, map[string]any{"back": true}, "Actions marker"); err != nil {
		return fmt.Errorf("back: %w", err)
	}
	if v, err := s.script(where, "document.title"); err != nil || !strings.Contains(v, "Latchkey check actions") {
		return fmt.Errorf("a script's result: %q (%w)", v, err)
	}
	if err := s.pageActions(where, home, p); err != nil {
		return err
	}
	// a confirm the page asks after a click waits for Claude, and the answer goes back to it
	t, err = s.look(where, nil)
	if err != nil {
		return err
	}
	if _, err := s.act(where, map[string]any{"action": "click", "ref": refFor(t, "Remove item")}); err != nil {
		return err
	}
	if !waitFor(10*time.Second, func() bool {
		t, err := s.m.text("browser_look", where)
		return err == nil && strings.Contains(t, "Latchkey check: remove item?")
	}) {
		return errors.New("the page's confirm wasn't said to be waiting")
	}
	if _, err := s.act(where, map[string]any{"action": "dialog", "confirm": true}); err != nil {
		return err
	}
	if !waitFor(10*time.Second, func() bool {
		v, err := s.script(where, "document.title")
		return err == nil && strings.Contains(v, "asked:true")
	}) {
		return errors.New("the confirm's OK didn't reach the page")
	}
	// another site; a PDF saved; tabs; a screenshot; close
	t, err = s.look(where, nil)
	if err != nil {
		return err
	}
	if _, err := s.act(where, map[string]any{"action": "click", "ref": refFor(t, "Other site")}, "Other site marker"); err != nil {
		return fmt.Errorf("a link to another site: %w", err)
	}
	t, err = s.ask("browser_look", map[string]any{"url": p.site() + "/report.pdf"})
	if err != nil {
		return err
	}
	pdfPage := pageName(t)
	if pdfPage != "" {
		opened = append(opened, pdfPage)
	}
	since := time.Now().Add(-time.Second)
	if _, err := s.act(map[string]any{"page": pdfPage}, map[string]any{"action": "download"}); err != nil {
		return fmt.Errorf("the PDF page saved: %w", err)
	}
	var pdf string
	if !waitFor(30*time.Second, func() bool {
		pdf = newestPDF(filepath.Join(home, "Downloads"), since)
		return pdf != ""
	}) {
		return errors.New("no PDF in Downloads after downloading the PDF page")
	}
	_ = os.Remove(pdf)
	if _, err := s.ask("browser_look", map[string]any{"tabs": true}, pg); err != nil {
		return fmt.Errorf("the tab list: %w", err)
	}
	res, err := s.m.call("browser_look", map[string]any{"page": pg, "screenshot": true})
	if err != nil || res.IsError || !slices.ContainsFunc(res.Content, func(c mcp.Content) bool { _, ok := c.(*mcp.ImageContent); return ok }) {
		return fmt.Errorf("a screenshot of the page: %w %q", err, short(e2erelay.TextOf(res)))
	}
	for _, x := range opened {
		if _, err := s.act(map[string]any{"page": x}, map[string]any{"action": "close"}); err != nil {
			return err
		}
	}
	closed := opened
	opened = nil
	t, err = s.ask("browser_look", map[string]any{"tabs": true})
	if err != nil {
		return err
	}
	for _, x := range closed {
		if strings.Contains(t, `"`+x+`"`) {
			return fmt.Errorf("the closed page %s is still listed: %q", x, short(t))
		}
	}
	step("browser: opened, clicked same and other site, back, script, typed and sent, keys, select, hover, scroll, upload, download (link and PDF), a confirm answered, tabs, screenshot, closed")
	return nil
}

// newestPDF is a PDF saved in dir since since.
func newestPDF(dir string, since time.Time) string {
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		info, err := e.Info()
		if err == nil && !e.IsDir() && strings.HasSuffix(strings.ToLower(e.Name()), ".pdf") && !info.ModTime().Before(since) {
			return filepath.Join(dir, e.Name())
		}
	}
	return ""
}

// safariWindows is how many visible Safari windows with tabs there are (a closed window lingers
// invisible for a while: .claude/rules/macos.md).
func safariWindows() (int, error) {
	out, err := osaOut(`tell application "System Events" to if not (exists process "Safari") then return "0"
set n to 0
tell application "Safari"
repeat with w in windows
try
if visible of w and (count of tabs of w) > 0 then set n to n + 1
end try
end repeat
end tell
return n as text`)
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(out)
}

// safari: the copy's real Safari (former safari-check): one of the owner's tabs (opened here, in
// the background, as an owner would have it) and a Safari tab of Claude's.
func (s *sandbox) safari() error {
	p, err := startWebPages(s.ctx, s.m.marker)
	if err != nil {
		return err
	}
	defer p.close()
	home, _ := os.UserHomeDir()
	before, err := safariWindows()
	if err != nil {
		return fmt.Errorf("counting Safari's windows: %w", err)
	}
	// The owner's tab, opened in the background (not a Latchkey call, so not watched).
	ownerURL := p.site() + "/owner"
	if err := runQuiet("/usr/bin/open", "-g", "-a", "Safari", ownerURL); err != nil {
		return err
	}
	defer func() {
		_ = osa(`on run argv
tell application "Safari"
repeat with w in windows
repeat with t in (tabs of w)
if (URL of t) starts with (item 1 of argv) or (URL of t) starts with (item 2 of argv) then close t
end repeat
end repeat
end tell
end run`, p.site(), p.other())
	}()
	var ownerRef string
	if !waitFor(30*time.Second, func() bool {
		t, err := s.m.text("browser_look", map[string]any{"tabs": true})
		if err != nil {
			return false
		}
		for line := range strings.SplitSeq(t, "\n") {
			if strings.Contains(line, "Owner page") || strings.Contains(line, "/owner") {
				ownerRef = tabRefRE.FindString(line)
			}
		}
		return ownerRef != ""
	}) {
		return errors.New("the owner's Safari tab isn't in the tab list")
	}
	owner := map[string]any{"tab": ownerRef}
	if _, err := s.look(owner, nil, "Owner page marker "+s.m.marker); err != nil {
		return fmt.Errorf("reading the owner's tab: %w", err)
	}
	t, err := s.look(owner, nil)
	if err != nil {
		return err
	}
	if _, err := s.act(owner, map[string]any{"action": "click", "ref": refFor(t, "Owner link")}); err != nil {
		return fmt.Errorf("a click in the owner's tab: %w", err)
	}
	if !waitFor(10*time.Second, func() bool { return p.saw("/next") }) {
		return errors.New("the click in the owner's tab didn't load the next page")
	}
	if _, err := s.look(owner, map[string]any{"back": true}, "Owner page marker"); err != nil {
		return fmt.Errorf("back in the owner's tab: %w", err)
	}
	// Claude's tab in Safari: same-site and cross-site clicks keep it
	t, err = s.ask("browser_look", map[string]any{"url": p.site() + "/", "show_in_safari": true}, "Actions marker "+s.m.marker)
	if err != nil {
		return err
	}
	pg := pageName(t)
	if pg == "" {
		return fmt.Errorf("show_in_safari gave the page no name: %q", short(t))
	}
	claude := map[string]any{"page": pg}
	defer func() { _, _ = s.m.text("browser_act", map[string]any{"action": "close", "page": pg}) }()
	if _, err := s.act(claude, map[string]any{"action": "click", "ref": refFor(t, "Next page")}, "Next page marker"); err != nil {
		return fmt.Errorf("a same-site click in Claude's Safari tab: %w", err)
	}
	if _, err := s.ask("browser_look", map[string]any{"tabs": true}, pg); err != nil {
		return fmt.Errorf("after a same-site click the tab list lacks Claude's tab: %w", err)
	}
	if _, err := s.look(claude, map[string]any{"back": true}, "Actions marker"); err != nil {
		return fmt.Errorf("back in Claude's tab: %w", err)
	}
	if err := s.pageActions(claude, home, p); err != nil {
		return fmt.Errorf("in Claude's Safari tab: %w", err)
	}
	// text arrives composed: é is one character, U+00E9, in the page and in the shell
	if v, err := s.script(claude, "'é'.length + ' ' + 'é'.charCodeAt(0)"); err != nil || !strings.Contains(v, "1 233") {
		return fmt.Errorf("a script's é in Safari: %q (%w), want 1 233", v, err)
	}
	if _, err := s.ask("shell_run", map[string]any{"command": "printf '%s' 'é' | od -An -tx1"}, "c3 a9"); err != nil {
		return fmt.Errorf("the shell's é: %w", err)
	}
	// a long page comes in parts, and offset reads on
	t, err = s.look(claude, map[string]any{"url": p.site() + "/long"})
	if err != nil {
		return err
	}
	if strings.Contains(t, "Last words "+s.m.marker) {
		return fmt.Errorf("the long page came in one part (%d characters)", len(t))
	}
	off := offsetRE.FindStringSubmatch(t)
	if off == nil {
		return fmt.Errorf("the long page's first part doesn't say where to read on: %q", short(t[max(0, len(t)-400):]))
	}
	if _, err := s.look(claude, map[string]any{"offset": atoi(off[1])}); err != nil {
		return fmt.Errorf("reading on at offset %s: %w", off[1], err)
	}
	t, err = s.look(claude, map[string]any{"url": p.site() + "/"})
	if err != nil {
		return err
	}
	if _, err := s.act(claude, map[string]any{"action": "click", "ref": refFor(t, "Other site")}, "Other site marker"); err != nil {
		return fmt.Errorf("a cross-site click in Claude's Safari tab: %w", err)
	}
	if _, err := s.look(claude, nil, "Other site marker"); err != nil {
		return fmt.Errorf("reading the tab of Claude's after the cross-site click: %w", err)
	}
	// closed: Claude's tab and the owner's tab; nothing of the check's left
	if _, err := s.act(claude, map[string]any{"action": "close"}); err != nil {
		return err
	}
	if _, err := s.act(owner, map[string]any{"action": "close"}); err != nil {
		return fmt.Errorf("closing the owner's tab: %w", err)
	}
	if t, err = s.ask("browser_look", map[string]any{"tabs": true}); err != nil {
		return err
	}
	if strings.Contains(t, `"`+pg+`"`) || strings.Contains(t, "Owner page") {
		return fmt.Errorf("closed tabs are still listed: %q", short(t))
	}
	if !waitFor(10*time.Second, func() bool { n, err := safariWindows(); return err == nil && n <= before }) {
		n, _ := safariWindows()
		return fmt.Errorf("after the check Safari has %d windows, %d before", n, before)
	}
	step("safari: the owner's tab listed, read, clicked, back, closed; Claude's tab kept through same- and cross-site clicks, every action, composed é, a long page in parts; nothing left")
	return nil
}

// offsetRE finds where an answer says to read on ("offset 12000").
var offsetRE = regexp.MustCompile(`offset[ :=]+(\d+)`)

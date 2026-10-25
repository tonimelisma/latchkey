// Command maccheck runs the Mac app integration check (task T065) on this Mac, with no manual
// steps: a private relay, sign-up and pairing in headless Chrome, and the Mac app's real
// connection code (the LiveRelayTests Swift test) dialing in through a local proxy. It checks a
// live battery_status against pmset, a disabled capability disappearing, a silently cut network
// being noticed, and reconnection.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
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

	"github.com/tonimelisma/latchkey/relay/internal/account"
	"github.com/tonimelisma/latchkey/relay/internal/e2e"
	"github.com/tonimelisma/latchkey/relay/internal/oauth"
	"github.com/tonimelisma/latchkey/relay/internal/server"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "FAIL:", err)
		os.Exit(1)
	}
	fmt.Println("PASS")
}

func step(format string, args ...any) { fmt.Printf("• "+format+"\n", args...) }

func run() error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	dir, err := os.MkdirTemp("", "latchkey-maccheck-")
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(dir) }()

	step("starting a private relay")
	db, err := store.Open(ctx, filepath.Join(dir, "relay.db"))
	if err != nil {
		return err
	}
	defer func() { _ = db.Close() }()
	lc := &net.ListenConfig{}
	l, err := lc.Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	relayAddr := l.Addr().String()
	base := "http://localhost:" + port(relayAddr)
	public, _ := url.Parse(base)
	mail := &account.MemoryMailer{}
	r, err := server.New(ctx, server.Options{
		PublicURL: public, Store: db, Mailer: mail,
		AllowedClients: oauth.AnyClientHost(), // the check registers its own throwaway client
		Logger:         slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
	if err != nil {
		return err
	}
	srv := &http.Server{Handler: r.Handler, ReadHeaderTimeout: 10 * time.Second}
	go func() { _ = srv.Serve(l) }()
	defer func() { r.Hub.Close(); _ = srv.Close() }()

	px, err := newProxy(ctx, relayAddr)
	if err != nil {
		return err
	}
	defer px.close()
	viaProxy := "http://localhost:" + port(px.addr)

	step("signing up and pairing in headless Chrome")
	b, err := e2e.NewBrowser(ctx)
	if err != nil {
		return err
	}
	defer b.Close()
	codeRE := regexp.MustCompile(`\b\d{6}\b`)
	if err := b.SignUp(base, "mac@example.com", func(email string) (string, error) {
		for _, m := range mail.Sent() {
			if m.To == email {
				return codeRE.FindString(m.Body), nil
			}
		}
		return "", errors.New("no email")
	}); err != nil {
		return err
	}
	code, err := b.PairCode(base, "Live Test Mac")
	if err != nil {
		return err
	}
	token, err := b.Token(ctx, base)
	if err != nil {
		return err
	}

	step("starting the Mac app's connection code (Swift test) through the proxy")
	control := filepath.Join(dir, "control")
	if err := os.WriteFile(control, nil, 0o600); err != nil {
		return err
	}
	macos, _ := filepath.Abs("../macos")
	test := exec.CommandContext(ctx, "xcodebuild", "-project", "Latchkey.xcodeproj", "-scheme", "Latchkey",
		"-destination", "platform=macOS", "-derivedDataPath", "build/DerivedData",
		"test", "-only-testing:LatchkeyTests/LiveRelayTests")
	test.Dir = macos
	test.Env = append(os.Environ(),
		"TEST_RUNNER_LATCHKEY_LIVE_RELAY="+viaProxy, "TEST_RUNNER_LATCHKEY_LIVE_CODE="+code,
		"TEST_RUNNER_LATCHKEY_LIVE_CONTROL="+control)
	logFile := filepath.Join(dir, "xcodebuild.log")
	out, _ := os.Create(logFile)
	test.Stdout, test.Stderr = out, out
	if err := test.Start(); err != nil {
		return err
	}
	testDone := make(chan error, 1)
	go func() { testDone <- test.Wait() }()
	send := func(cmd string) {
		f, _ := os.OpenFile(control, os.O_APPEND|os.O_WRONLY, 0o600)
		_, _ = f.WriteString(cmd + "\n")
		_ = f.Close()
	}
	fail := func(err error) error {
		send("done")
		data, _ := os.ReadFile(logFile)
		return fmt.Errorf("%w\n--- xcodebuild log (tail) ---\n%s", err, tail(string(data), 40))
	}

	users, err := activeDevice(ctx, db)
	online := func() bool {
		d, err := users()
		return err == nil && r.Hub.Online(d)
	}
	if err != nil {
		return fail(err)
	}
	if !waitFor(4*time.Minute, online) {
		return fail(errors.New("the Mac app never connected"))
	}
	step("the Mac app connected")

	cs, err := mcpClient(ctx, base, token)
	if err != nil {
		return fail(err)
	}
	defer func() { _ = cs.Close() }()

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "battery_status", Arguments: map[string]any{}})
	if err != nil {
		return fail(err)
	}
	got := textOf(res)
	want, hasBattery := pmsetBattery()
	switch {
	case !hasBattery && !res.IsError:
		return fail(fmt.Errorf("no battery, but battery_status answered %q", got))
	case hasBattery && (res.IsError || !strings.Contains(got, `"battery_percent":`)):
		return fail(fmt.Errorf("battery_status failed: %q", got))
	case hasBattery:
		pct := regexp.MustCompile(`"battery_percent":(\d+)`).FindStringSubmatch(got)
		n, _ := strconv.Atoi(pct[1])
		if n < want-1 || n > want+1 {
			return fail(fmt.Errorf("battery_status says %d%%, pmset says %d%%", n, want))
		}
	}
	step("battery_status from the real Mac code: %s (pmset: %d%%)", got, want)

	step("turning the test tool off in the app")
	send("tools-off")
	if !waitFor(10*time.Second, func() bool {
		tools, err := cs.ListTools(ctx, nil)
		return err == nil && !slices.ContainsFunc(tools.Tools, func(t *mcp.Tool) bool { return t.Name == "battery_status" })
	}) {
		return fail(errors.New("battery_status still listed after it was turned off (SC-08)"))
	}
	step("battery_status disappeared from Claude's tool list (SC-08)")

	step("cutting the network silently")
	px.blackhole()
	start := time.Now()
	if !waitFor(60*time.Second, func() bool { return !online() }) {
		return fail(errors.New("the relay never noticed the Mac was gone"))
	}
	detect := time.Since(start)
	if detect > 45*time.Second {
		return fail(fmt.Errorf("offline noticed after %s; SC-04 allows 45 s", detect.Round(time.Second)))
	}
	step("relay marked the Mac offline after %s (SC-04: within 45 s)", detect.Round(time.Second))

	time.Sleep(5 * time.Second)
	step("restoring the network (as a network change, which the app reacts to)")
	px.restore()
	send("reconnect-now")
	start = time.Now()
	if !waitFor(60*time.Second, online) {
		return fail(errors.New("the Mac app never reconnected"))
	}
	back := time.Since(start)
	step("reconnected %s after the network returned (SC-05: within 10 s)", back.Round(100*time.Millisecond))
	if back > 10*time.Second {
		return fail(fmt.Errorf("reconnect took %s; SC-05 allows 10 s", back.Round(time.Second)))
	}

	step("suspending the account, as the relay's operator would")
	deviceID, err := users()
	if err != nil {
		return fail(err)
	}
	if _, _, err := db.SuspendUser(ctx, "mac@example.com", "check", "maccheck", time.Now()); err != nil {
		return fail(err)
	}
	r.Hub.Suspend(deviceID)
	if !waitFor(10*time.Second, func() bool { return !online() }) {
		return fail(errors.New("the suspended account's Mac stayed connected"))
	}
	time.Sleep(2 * time.Second) // the app has seen the close and, if it retried, been refused
	send("expect-suspended")
	send("wake") // a wake or a network change tries at once, and is refused while suspended
	time.Sleep(2 * time.Second)
	if online() {
		return fail(errors.New("a suspended account's Mac connected"))
	}
	if d, err := db.Device(ctx, deviceID); err != nil {
		return fail(err)
	} else if !d.RevokedAt.IsZero() {
		return fail(errors.New("the suspension revoked the Mac's pairing"))
	}
	step("the Mac app shows the suspension, keeps its pairing, and is refused when it tries")

	if _, _, err := db.UnsuspendUser(ctx, "mac@example.com", "maccheck", time.Now()); err != nil {
		return fail(err)
	}
	send("wake-again")
	start = time.Now()
	if !waitFor(30*time.Second, online) {
		return fail(errors.New("the Mac app never came back after the suspension was lifted (FR-204)"))
	}
	step("suspension lifted: the Mac app reconnected by itself %s after its next try", time.Since(start).Round(100*time.Millisecond))

	send("done")
	select {
	case err := <-testDone:
		if err != nil {
			data, _ := os.ReadFile(logFile)
			return fmt.Errorf("the Swift test failed: %w\n%s", err, tail(string(data), 40))
		}
	case <-time.After(3 * time.Minute):
		return errors.New("the Swift test did not finish")
	}
	return nil
}

func port(addr string) string {
	_, p, _ := net.SplitHostPort(addr)
	return p
}

func waitFor(d time.Duration, cond func() bool) bool {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			return true
		}
		time.Sleep(100 * time.Millisecond)
	}
	return false
}

func tail(s string, n int) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

// activeDevice returns a lookup of the single test user's paired Mac.
func activeDevice(ctx context.Context, db *store.Store) (func() (string, error), error) {
	u, err := db.UserByEmail(ctx, "mac@example.com")
	if err != nil {
		return nil, err
	}
	return func() (string, error) {
		d, err := db.ActiveDevice(ctx, u.ID)
		return d.ID, err
	}, nil
}

func pmsetBattery() (int, bool) {
	out, err := exec.CommandContext(context.Background(), "/usr/bin/pmset", "-g", "batt").Output()
	if err != nil {
		return 0, false
	}
	m := regexp.MustCompile(`(\d+)%`).FindStringSubmatch(string(out))
	if m == nil {
		return 0, false
	}
	n, _ := strconv.Atoi(m[1])
	return n, true
}

type bearer struct{ token string }

func (b bearer) RoundTrip(r *http.Request) (*http.Response, error) {
	r = r.Clone(r.Context())
	r.Header.Set("Authorization", "Bearer "+b.token)
	return http.DefaultTransport.RoundTrip(r)
}

func mcpClient(ctx context.Context, base, token string) (*mcp.ClientSession, error) {
	c := mcp.NewClient(&mcp.Implementation{Name: "maccheck", Version: "1"}, nil)
	return c.Connect(ctx, &mcp.StreamableClientTransport{
		Endpoint: base + "/mcp", HTTPClient: &http.Client{Transport: bearer{token}}, MaxRetries: -1,
	}, &mcp.ClientSessionOptions{ProtocolVersion: "2025-11-25"})
}

func textOf(res *mcp.CallToolResult) string {
	var parts []string
	for _, c := range res.Content {
		if t, ok := c.(*mcp.TextContent); ok {
			parts = append(parts, t.Text)
		}
	}
	return strings.Join(parts, "\n")
}

// proxy forwards TCP to the relay and can silently drop traffic, like a network that vanished
// without closing connections.
type proxy struct {
	addr   string
	l      net.Listener
	target string

	mu     sync.Mutex
	paused bool
	conns  []net.Conn
}

func newProxy(ctx context.Context, target string) (*proxy, error) {
	l, err := (&net.ListenConfig{}).Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	p := &proxy{addr: l.Addr().String(), l: l, target: target}
	go p.accept(ctx)
	return p, nil
}

func (p *proxy) accept(ctx context.Context) {
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

func (p *proxy) pipe(dst, src net.Conn) {
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

func (p *proxy) blackhole() {
	p.mu.Lock()
	p.paused = true
	p.mu.Unlock()
}

// restore closes every connection from before (they died with the network) and forwards again.
func (p *proxy) restore() {
	p.mu.Lock()
	for _, c := range p.conns {
		_ = c.Close()
	}
	p.conns = nil
	p.paused = false
	p.mu.Unlock()
}

func (p *proxy) close() {
	_ = p.l.Close()
	p.restore()
}

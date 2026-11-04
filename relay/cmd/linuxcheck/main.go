// Command linuxcheck is spec 010's end-to-end check (plan D14): a private relay on this computer,
// a pretend Mac, and the real Linux program in a Debian container with systemd, installed the way
// an Owner installs it (install.sh, a code typed on the relay's page, sudo starting the service).
// A real MCP client with a real OAuth token then drives both machines through the relay: the
// machines tool, choosing the machine, shell with sudo and leftovers, files with a picture,
// turning Shell off on the server, pause, a reboot, and uninstalling. With -claude, real Claude
// Code runs a command on the server too. Nobody needs to touch anything; Docker must be running.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/tonimelisma/latchkey/relay/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/account"
	"github.com/tonimelisma/latchkey/relay/internal/e2e"
	"github.com/tonimelisma/latchkey/relay/internal/oauth"
	"github.com/tonimelisma/latchkey/relay/internal/server"
	"github.com/tonimelisma/latchkey/relay/internal/store"
	"github.com/tonimelisma/latchkey/relay/internal/testagent"
)

func main() {
	_ = flag.Bool("docker", true, "run the server program in a Debian container (the only mode)")
	claude := flag.Bool("claude", false, "also ask real Claude Code to use the server")
	model := flag.String("model", "haiku", "Claude model for -claude")
	keep := flag.Bool("keep", false, "leave the container running afterwards, for a look")
	flag.Parse()
	c := &check{claude: *claude, model: *model, keep: *keep}
	err := c.run()
	c.cleanup()
	if err != nil {
		fmt.Fprintln(os.Stderr, "FAIL:", err)
		os.Exit(1)
	}
	fmt.Println("PASS: a Mac and a Linux server behind one connector; the server installed, paired, used, rebooted, and uninstalled.")
}

type check struct {
	claude, keep bool
	model        string
	ctx          context.Context
	dir          string
	container    string
	cleanups     []func()
	cs           *mcp.ClientSession
}

func step(format string, args ...any) { fmt.Printf("• "+format+"\n", args...) }

func (c *check) cleanup() {
	for i := len(c.cleanups) - 1; i >= 0; i-- {
		c.cleanups[i]()
	}
}

func (c *check) defer_(f func()) { c.cleanups = append(c.cleanups, f) }

// docker runs a docker command and returns its output.
func docker(ctx context.Context, args ...string) (string, error) {
	out, err := exec.CommandContext(ctx, "docker", args...).CombinedOutput() //nolint:gosec // docker, with the check's own arguments
	if err != nil {
		return string(out), fmt.Errorf("docker %s: %w: %s", strings.Join(args, " "), err, out)
	}
	return string(out), nil
}

// asToni runs a command in the container as the server's owner.
func (c *check) asToni(command string) (string, error) {
	return docker(c.ctx, "exec", "-u", "toni", "-e", "HOME=/home/toni", "-w", "/home/toni", c.container, "bash", "-lc", command) // a login shell, as an SSH session
}

func (c *check) run() error {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	c.defer_(cancel)
	c.ctx = ctx
	if _, err := docker(ctx, "info"); err != nil {
		return errors.New("docker isn't running")
	}
	dir, err := os.MkdirTemp("", "latchkey-linuxcheck-")
	if err != nil {
		return err
	}
	c.dir = dir
	c.defer_(func() { _ = os.RemoveAll(dir) })
	repo, err := filepath.Abs("..")
	if err != nil {
		return err
	}

	step("starting a private relay")
	db, err := store.Open(ctx, filepath.Join(dir, "relay.db"))
	if err != nil {
		return err
	}
	c.defer_(func() { _ = db.Close() })
	l, err := (&net.ListenConfig{}).Listen(ctx, "tcp", "0.0.0.0:0") // the container reaches it as host.docker.internal
	if err != nil {
		return err
	}
	port := l.Addr().(*net.TCPAddr).Port
	base := fmt.Sprintf("http://localhost:%d", port)
	fromContainer := fmt.Sprintf("http://host.docker.internal:%d", port)
	public, _ := url.Parse(base)
	mail := &account.MemoryMailer{}
	r, err := server.New(ctx, server.Options{
		PublicURL: public, Store: db, Mailer: mail, Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
		AllowedClients: oauth.AnyClientHost(), // the check registers its own throwaway client
	})
	if err != nil {
		return err
	}
	srv := &http.Server{Handler: r.Handler, ReadHeaderTimeout: 10 * time.Second}
	go func() { _ = srv.Serve(l) }()
	c.defer_(func() { r.Hub.Close(); _ = srv.Close() })

	step("signing up in headless Chrome")
	b, err := e2e.NewBrowser(ctx)
	if err != nil {
		return fmt.Errorf("browser: %w", err)
	}
	c.defer_(b.Close)
	codeRE := regexp.MustCompile(`\b\d{6}\b`)
	if err := b.SignUp(base, "check@example.com", func(email string) (string, error) {
		for _, m := range mail.Sent() {
			if m.To == email {
				return codeRE.FindString(m.Body), nil
			}
		}
		return "", errors.New("no email")
	}); err != nil {
		return fmt.Errorf("sign-up: %w", err)
	}
	owner, err := db.UserByEmail(ctx, "check@example.com")
	if err != nil {
		return err
	}

	step("pairing a pretend Mac that offers a shell too")
	code, err := b.PairCode(base, "Pretend MacBook")
	if err != nil {
		return err
	}
	mac := testagent.New("ws"+strings.TrimPrefix(base, "http")+"/agent/v1", "")
	mac.Tools = append(mac.Tools, &mcp.Tool{
		Name: "shell_run", Description: "Runs a command in the Mac owner's login shell (zsh).",
		InputSchema: map[string]any{"type": "object", "properties": map[string]any{"command": map[string]any{"type": "string"}}},
	})
	mac.Handler = func(_ context.Context, call *agentproto.Call) *agentproto.Result {
		content, _ := json.Marshal([]map[string]string{{"type": "text", "text": "the pretend Mac ran " + call.Tool}})
		return &agentproto.Result{ID: call.ID, Content: content}
	}
	if mac.DeviceID, err = e2e.ExchangePairingCode(ctx, base, code, mac.PublicKeyDER(), "Pretend MacBook"); err != nil {
		return err
	}
	macConn, err := mac.Dial(ctx)
	if err != nil {
		return err
	}

	step("building the Linux program and a release folder for install.sh")
	archOut, err := docker(ctx, "info", "--format", "{{.Architecture}}")
	if err != nil {
		return err
	}
	goarch := map[string]string{"aarch64": "arm64", "x86_64": "amd64"}[strings.TrimSpace(archOut)]
	if goarch == "" {
		return fmt.Errorf("unknown Docker architecture %q", archOut)
	}
	rel := filepath.Join(dir, "release")
	if err := os.MkdirAll(rel, 0o750); err != nil {
		return err
	}
	bin := filepath.Join(rel, "latchkey-linux-"+goarch)
	build := exec.CommandContext(ctx, "go", "build", "-trimpath", "-ldflags", "-X main.version=0.0.0-check", "-o", bin, "./cmd/latchkey") //nolint:gosec // go build of this repository's Linux program
	build.Dir = filepath.Join(repo, "linux")
	build.Env = append(os.Environ(), "CGO_ENABLED=0", "GOOS=linux", "GOARCH="+goarch)
	if out, err := build.CombinedOutput(); err != nil {
		return fmt.Errorf("build: %w: %s", err, out)
	}
	data, err := os.ReadFile(bin) //nolint:gosec // the program the check just built
	if err != nil {
		return err
	}
	sum := sha256.Sum256(data)
	if err := os.WriteFile(filepath.Join(rel, "SHA256SUMS"), fmt.Appendf(nil, "%x  latchkey-linux-%s\n", sum, goarch), 0o600); err != nil { //nolint:gosec // a file in the check's own temporary folder
		return err
	}
	installSh, err := os.ReadFile(filepath.Join(repo, "linux", "install.sh")) //nolint:gosec // this repository's install.sh
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(rel, "install.sh"), installSh, 0o600); err != nil { //nolint:gosec // a file in the check's own temporary folder
		return err
	}
	fl, err := (&net.ListenConfig{}).Listen(ctx, "tcp", "0.0.0.0:0")
	if err != nil {
		return err
	}
	files := &http.Server{Handler: http.FileServer(http.Dir(rel)), ReadHeaderTimeout: 10 * time.Second}
	go func() { _ = files.Serve(fl) }()
	c.defer_(func() { _ = files.Close() })
	releaseURL := fmt.Sprintf("http://host.docker.internal:%d", fl.Addr().(*net.TCPAddr).Port)

	step("starting a Debian server with systemd")
	if out, err := exec.CommandContext(ctx, "docker", "build", "-q", "-t", "latchkey-linux-test", filepath.Join(repo, "linux", "test")).CombinedOutput(); err != nil { //nolint:gosec // docker build of this repository's test image
		return fmt.Errorf("image: %w: %s", err, out)
	}
	c.container = fmt.Sprintf("latchkey-linuxcheck-%d", os.Getpid())
	if _, err := docker(ctx, "run", "-d", "--name", c.container, "--hostname", "homeserver", "--privileged", "--cgroupns=host",
		"-v", "/sys/fs/cgroup:/sys/fs/cgroup:rw", "--tmpfs", "/tmp:exec", "--add-host", "host.docker.internal:host-gateway",
		"latchkey-linux-test"); err != nil {
		return err
	}
	if !c.keep {
		c.defer_(func() { _, _ = docker(context.Background(), "rm", "-f", c.container) })
	} else {
		c.defer_(func() { fmt.Println("container left running:", c.container) })
	}
	if err := c.waitSystemd(); err != nil {
		return err
	}

	step("installing with install.sh as the owner; typing the code on the relay's page")
	installCmd := exec.CommandContext(ctx, "docker", "exec", "-u", "toni", "-e", "HOME=/home/toni", "-w", "/home/toni", c.container, "sh", "-c", //nolint:gosec // docker exec in the check's own container
		fmt.Sprintf("curl -fsSL %s/install.sh | LATCHKEY_BASE_URL=%s LATCHKEY_TEST_INSECURE_RELAY=1 sh -s -- %s", releaseURL, releaseURL, fromContainer))
	stdout, err := installCmd.StdoutPipe()
	if err != nil {
		return err
	}
	var installOut, installErr bytes.Buffer
	installCmd.Stderr = &installErr
	if err := installCmd.Start(); err != nil {
		return err
	}
	userCodeRE := regexp.MustCompile(`\b[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}\b`)
	scanner := bufio.NewScanner(stdout)
	userCode := ""
	for scanner.Scan() {
		line := scanner.Text()
		installOut.WriteString(line + "\n")
		if m := userCodeRE.FindString(line); m != "" {
			userCode = m
			break
		}
	}
	if userCode == "" {
		return fmt.Errorf("install.sh showed no code:\n%s", installOut.String())
	}
	if err := b.LinkCode(base, userCode, "homeserver"); err != nil {
		return err
	}
	for scanner.Scan() { // the rest, until install.sh ends
		installOut.WriteString(scanner.Text() + "\n")
	}
	if err := installCmd.Wait(); err != nil {
		return fmt.Errorf("install.sh: %w:\n%s%s", err, installOut.String(), installErr.String())
	}
	if !strings.Contains(installOut.String(), "Done. Claude can reach this server") {
		return fmt.Errorf("install.sh didn't finish:\n%s%s", installOut.String(), installErr.String())
	}
	server, err := c.waitLinuxOnline(db, r, owner.ID, true)
	if err != nil {
		return err
	}
	step("the server connected by itself as %q", server.Name)

	step("approving an MCP client and connecting a real MCP client")
	token, err := b.Token(ctx, base)
	if err != nil {
		return err
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "linuxcheck", Version: "1"}, nil)
	cs, err := client.Connect(ctx, &mcp.StreamableClientTransport{
		Endpoint: base + "/mcp", HTTPClient: &http.Client{Transport: bearer(token)}, MaxRetries: -1,
	}, nil)
	if err != nil {
		return err
	}
	c.cs = cs
	c.defer_(func() { _ = cs.Close() })

	if err := c.checkTools(); err != nil {
		return err
	}
	if err := c.checkShellAndFiles(); err != nil {
		return err
	}
	if c.claude {
		if err := c.askClaude(base, token); err != nil {
			return err
		}
	}
	if err := c.checkSettings(); err != nil {
		return err
	}
	if err := c.checkLog(); err != nil {
		return err
	}

	step("rebooting the server: Latchkey comes back with nobody logged in")
	if _, err := docker(ctx, "restart", c.container); err != nil {
		return err
	}
	if err := c.waitSystemd(); err != nil {
		return err
	}
	if _, err := c.waitLinuxOnline(db, r, owner.ID, true); err != nil {
		return err
	}

	step("the Mac goes offline: unnamed calls go to the server, the only one online")
	_ = macConn.Close()
	deadline := time.Now().Add(10 * time.Second)
	for r.Hub.Online(mac.DeviceID) && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	text, isErr, err := c.call("shell_run", map[string]any{"command": "echo from-the-server"})
	if err != nil || isErr || !strings.Contains(text, "from-the-server") || !strings.Contains(text, "Other machines: Pretend MacBook (Mac, offline") {
		return fmt.Errorf("unnamed shell_run with the Mac offline: %w %q", err, text)
	}

	step("uninstalling: the server leaves the account and nothing is left on it")
	if out, err := c.asToni("latchkey uninstall"); err != nil || !strings.Contains(out, "Removed from your account") {
		return fmt.Errorf("uninstall: %w\n%s", err, out)
	}
	if _, err := c.waitLinuxOnline(db, r, owner.ID, false); err != nil {
		return err
	}
	if out, _ := c.asToni("ls -a ~/.config ~/.local/share ~/.local/lib ~/.cache 2>&1; systemctl is-enabled latchkey 2>&1; ls /etc/systemd/system/latchkey.service 2>&1"); strings.Contains(out, "latchkey ") ||
		!strings.Contains(out, "No such file") {
		return fmt.Errorf("something was left after uninstalling:\n%s", out)
	}
	return nil
}

type bearer string

func (b bearer) RoundTrip(r *http.Request) (*http.Response, error) {
	r = r.Clone(r.Context())
	r.Header.Set("Authorization", "Bearer "+string(b))
	// nosemgrep: scripts.semgrep.latchkey-outbound-http-guarded -- the check's MCP client, talking to its own relay on localhost
	return http.DefaultTransport.RoundTrip(r)
}

func (c *check) waitSystemd() error {
	deadline := time.Now().Add(90 * time.Second)
	for time.Now().Before(deadline) {
		out, _ := docker(c.ctx, "exec", c.container, "systemctl", "is-system-running")
		if strings.Contains(out, "running") || strings.Contains(out, "degraded") {
			return nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	return errors.New("systemd didn't start in the container")
}

// waitLinuxOnline waits until the account's Linux server is online (want true) or gone (false).
func (c *check) waitLinuxOnline(db *store.Store, r *server.Relay, userID string, want bool) (store.Device, error) {
	deadline := time.Now().Add(90 * time.Second)
	for time.Now().Before(deadline) {
		devices, err := db.ActiveDevices(c.ctx, userID)
		if err != nil {
			return store.Device{}, err
		}
		var server *store.Device
		for i, d := range devices {
			if d.Kind == store.KindLinux {
				server = &devices[i]
			}
		}
		switch {
		case want && server != nil && r.Hub.Online(server.ID):
			return *server, nil
		case !want && server == nil:
			return store.Device{}, nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	logs, _ := docker(c.ctx, "exec", c.container, "journalctl", "-u", "latchkey", "--no-pager", "-n", "40")
	if want {
		return store.Device{}, fmt.Errorf("the server didn't come online; its log:\n%s", logs)
	}
	return store.Device{}, fmt.Errorf("the server is still paired after uninstalling; its log:\n%s", logs)
}

// call calls a tool and returns its text.
func (c *check) call(name string, args map[string]any) (string, bool, error) {
	res, err := c.cs.CallTool(c.ctx, &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		return "", false, err
	}
	var b strings.Builder
	for _, content := range res.Content {
		if t, ok := content.(*mcp.TextContent); ok {
			b.WriteString(t.Text)
		}
	}
	return b.String(), res.IsError, nil
}

func (c *check) tools() (map[string]*mcp.Tool, error) {
	list, err := c.cs.ListTools(c.ctx, nil)
	if err != nil {
		return nil, err
	}
	out := map[string]*mcp.Tool{}
	for _, t := range list.Tools {
		out[t.Name] = t
	}
	return out, nil
}

func (c *check) checkTools() error {
	step("the tool list: machines, one shell_run with a part per kind, the server's files tools")
	tools, err := c.tools()
	if err != nil {
		return err
	}
	for _, name := range []string{"machines", "battery_status", "shell_run", "shell_check", "files_find", "files_read", "files_change", "latchkey_log"} {
		if tools[name] == nil {
			return fmt.Errorf("no %s in the tool list", name)
		}
	}
	d := tools["shell_run"].Description
	if !strings.HasPrefix(d, "On a Mac: Runs a command in the Mac owner's login shell (zsh).") || !strings.Contains(d, "\n\nOn a Linux server: Runs a command in bash") {
		return fmt.Errorf("shell_run's description: %q", d)
	}
	text, _, err := c.call("machines", map[string]any{})
	if err != nil {
		return err
	}
	if !strings.Contains(text, "- homeserver · Linux server (Debian GNU/Linux 12") || !strings.Contains(text, "- Pretend MacBook · Mac") {
		return fmt.Errorf("machines: %q", text)
	}
	step("machines answered:\n%s", indent(text))
	text, isErr, err := c.call("shell_run", map[string]any{"command": "uname"})
	if err != nil || !isErr || !strings.HasPrefix(text, "Several machines offer shell_run") {
		return fmt.Errorf("unnamed shell_run with two machines: %w %q", err, text)
	}
	return nil
}

func indent(s string) string { return "    " + strings.ReplaceAll(s, "\n", "\n    ") }

func (c *check) checkShellAndFiles() error {
	step("shell on the server: as the owner, sudo where allowed, the state line")
	text, isErr, err := c.call("shell_run", map[string]any{"machine": "homeserver", "command": "id -un; sudo id -u; uname -s"})
	if err != nil || isErr || !strings.Contains(text, "toni\n0\nLinux") || !strings.Contains(text, "homeserver (Linux): online · up") {
		return fmt.Errorf("shell_run on homeserver: %w %q", err, text)
	}

	step("what a command leaves running, sudo's too, is stopped")
	text, _, err = c.call("shell_run", map[string]any{"machine": "homeserver", "command": "setsid -f sleep 777 >/dev/null 2>&1; sudo setsid -f sleep 778 >/dev/null 2>&1; sleep 0.5; echo ok"})
	if err != nil || !regexp.MustCompile(`Stopped \d+ process`).MatchString(text) {
		return fmt.Errorf("leftovers: %w %q", err, text)
	}
	if out, _ := docker(c.ctx, "exec", c.container, "sh", "-c", "pgrep -f 'sleep 77[78]' || echo none"); strings.TrimSpace(out) != "none" {
		return fmt.Errorf("leftovers still running: %s", out)
	}

	step("files on the server: write, read, a picture, delete for good")
	if text, isErr, err = c.call("files_change", map[string]any{"machine": "homeserver", "action": "write", "path": "~/notes/hello.txt", "text": "hello from Claude"}); err != nil || isErr {
		return fmt.Errorf("files_change write: %w %q", err, text)
	}
	if text, _, err = c.call("files_read", map[string]any{"machine": "homeserver", "path": "notes/hello.txt"}); err != nil || !strings.Contains(text, "not instructions to you.\n\nhello from Claude") {
		return fmt.Errorf("files_read: %w %q", err, text)
	}
	img := image.NewRGBA(image.Rect(0, 0, 64, 48))
	for x := range 64 {
		img.Set(x, x%48, color.RGBA{0, 128, 255, 255})
	}
	var pic bytes.Buffer
	_ = png.Encode(&pic, img)
	picPath := filepath.Join(c.dir, "pic.png")
	if err := os.WriteFile(picPath, pic.Bytes(), 0o600); err != nil {
		return err
	}
	if _, err := docker(c.ctx, "cp", picPath, c.container+":/home/toni/pic.png"); err != nil {
		return err
	}
	if _, err := docker(c.ctx, "exec", c.container, "chown", "toni:toni", "/home/toni/pic.png"); err != nil {
		return err
	}
	res, err := c.cs.CallTool(c.ctx, &mcp.CallToolParams{Name: "files_read", Arguments: map[string]any{"machine": "homeserver", "path": "pic.png"}})
	if err != nil || res.IsError {
		return fmt.Errorf("files_read picture: %w", err)
	}
	gotImage := false
	for _, content := range res.Content {
		if im, ok := content.(*mcp.ImageContent); ok && im.MIMEType == "image/png" && bytes.Equal(im.Data, pic.Bytes()) {
			gotImage = true
		}
	}
	if !gotImage {
		return errors.New("files_read didn't return the picture as an image")
	}
	if text, isErr, err = c.call("files_change", map[string]any{"machine": "homeserver", "action": "delete", "path": "notes"}); err != nil || isErr || !strings.Contains(text, "for good") {
		return fmt.Errorf("files_change delete: %w %q", err, text)
	}
	if out, _ := c.asToni("test -e ~/notes && echo still-there || echo gone"); strings.TrimSpace(out) != "gone" {
		return errors.New("the deleted folder is still there")
	}
	return nil
}

func (c *check) checkSettings() error {
	step("turning Shell off on the server: Claude no longer sees it there")
	if out, err := c.asToni("latchkey shell off"); err != nil {
		return fmt.Errorf("latchkey shell off: %w %s", err, out)
	}
	ok := false
	for range 50 {
		text, _, _ := c.call("machines", map[string]any{})
		if strings.Contains(text, "- homeserver · Linux server") && !strings.Contains(between(text, "- homeserver", "\n"), "shell_run") {
			ok = true
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !ok {
		return errors.New("shell_run still offered on homeserver after latchkey shell off")
	}
	text, isErr, err := c.call("shell_run", map[string]any{"machine": "homeserver", "command": "id"})
	if err != nil || !isErr || !strings.HasPrefix(text, "homeserver doesn't offer shell_run") {
		return fmt.Errorf("shell_run on homeserver with Shell off: %w %q", err, text)
	}
	if _, err := c.asToni("latchkey shell on"); err != nil {
		return err
	}

	step("pausing on the server: calls are answered at once")
	if _, err := c.asToni("latchkey pause"); err != nil {
		return err
	}
	time.Sleep(1500 * time.Millisecond)
	text, isErr, _ = c.call("files_find", map[string]any{"machine": "homeserver"})
	if !isErr || !strings.Contains(text, "paused") {
		return fmt.Errorf("files_find while paused: %q", text)
	}
	if _, err := c.asToni("latchkey resume"); err != nil {
		return err
	}
	time.Sleep(1500 * time.Millisecond)
	if out, err := c.asToni("latchkey activity | tail -n 5; latchkey status"); err != nil || !strings.Contains(out, "files_find") || !strings.Contains(out, "Service: active") {
		return fmt.Errorf("activity and status on the server: %w\n%s", err, out)
	}
	return nil
}

// checkLog reads the server's own log through latchkey_log (spec 010 FR-1052 to FR-1056): its
// events since install, and nothing private: no relay address, no calls, commands, or paths.
func (c *check) checkLog() error {
	step("Latchkey's own log on the server: its events, nothing private")
	text, isErr, err := c.call("latchkey_log", map[string]any{"machine": "homeserver"})
	if err != nil || isErr {
		return fmt.Errorf("latchkey_log: %w %q", err, text)
	}
	for _, want := range []string{
		"Latchkey's own log on this server (Latchkey ", " app: Latchkey ", ` connection: Connected as "homeserver"`,
		" settings: Tools changed: shell off", " pause: The server's owner paused Claude's access",
		" pause: The server's owner resumed Claude's access",
	} {
		if !strings.Contains(text, want) {
			return fmt.Errorf("latchkey_log has no %q:\n%s", want, text)
		}
	}
	for _, private := range []string{"host.docker.internal", "localhost:", "shell_run", "files_", "id -un", "hello", "/home/toni", "sleep 77"} {
		if strings.Contains(text, private) {
			return fmt.Errorf("latchkey_log shows %q:\n%s", private, text)
		}
	}
	step("latchkey_log answered:\n%s", indent(text))
	text, isErr, err = c.call("latchkey_log", map[string]any{"machine": "homeserver", "category": "pause", "lines": 1})
	if err != nil || isErr || !strings.Contains(text, "pause: The server's owner resumed Claude's access") || strings.Contains(text, "paused Claude's access") {
		return fmt.Errorf("latchkey_log, one pause line: %w %q", err, text)
	}
	return nil
}

func between(s, from, to string) string {
	_, rest, ok := strings.Cut(s, from)
	if !ok {
		return ""
	}
	line, _, _ := strings.Cut(rest, to)
	return line
}

func (c *check) askClaude(base, token string) error {
	step("asking real Claude Code to run a command on the server")
	cfg := filepath.Join(c.dir, "mcp.json")
	data, _ := json.Marshal(map[string]any{"mcpServers": map[string]any{
		"latchkey": map[string]any{"type": "http", "url": base + "/mcp", "headers": map[string]string{"Authorization": "Bearer " + token}},
	}})
	if err := os.WriteFile(cfg, data, 0o600); err != nil {
		return err
	}
	out, err := e2e.AskClaude(c.ctx, c.model, cfg, "mcp__latchkey__machines,mcp__latchkey__shell_run",
		"Using the latchkey MCP server, run `cat /etc/debian_version` on the Linux server (find its name with the machines tool). Reply with only the command's output.")
	if err != nil {
		return err
	}
	if !regexp.MustCompile(`\b12\.\d+`).MatchString(out) {
		return fmt.Errorf("expected Debian 12's version in Claude's answer, got %q", out)
	}
	step("Claude answered %q", strings.TrimSpace(out))
	return nil
}

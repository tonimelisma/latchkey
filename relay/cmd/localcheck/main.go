// Command localcheck runs the Claude Code check (task T041): a private relay on localhost, sign-up
// and pairing in headless Chrome, then real Claude Code, non-interactively, calling the Mac's
// tools through the relay with a real OAuth token. Nobody needs to touch anything.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
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
	"strings"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/account"
	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/e2e"
	"github.com/tonimelisma/latchkey/relay/internal/server"
	"github.com/tonimelisma/latchkey/relay/internal/store"
	"github.com/tonimelisma/latchkey/relay/internal/testagent"
)

func main() {
	model := flag.String("model", "haiku", "Claude model for the check")
	flag.Parse()
	if err := run(*model); err != nil {
		fmt.Fprintln(os.Stderr, "FAIL:", err)
		os.Exit(1)
	}
	fmt.Println("PASS: Claude Code reached the pretend Mac through the relay, and got the offline answer once it left.")
}

func step(format string, args ...any) { fmt.Printf("• "+format+"\n", args...) }

func run(model string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	if _, err := exec.LookPath("claude"); err != nil {
		return errors.New("the claude command (Claude Code) is not installed")
	}
	dir, err := os.MkdirTemp("", "latchkey-check-")
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
	l, err := (&net.ListenConfig{}).Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	base := fmt.Sprintf("http://localhost:%d", l.Addr().(*net.TCPAddr).Port)
	public, _ := url.Parse(base)
	mail := &account.MemoryMailer{}
	quiet := slog.New(slog.NewTextHandler(io.Discard, nil))
	r, err := server.New(ctx, server.Options{PublicURL: public, Store: db, Mailer: mail, Logger: quiet})
	if err != nil {
		return err
	}
	srv := &http.Server{Handler: r.Handler, ReadHeaderTimeout: 10 * time.Second}
	go func() { _ = srv.Serve(l) }()
	defer func() { r.Hub.Close(); _ = srv.Close() }()

	step("signing up and creating a passkey in headless Chrome")
	b, err := e2e.NewBrowser(ctx)
	if err != nil {
		return fmt.Errorf("browser: %w", err)
	}
	defer b.Close()
	linkRE := regexp.MustCompile(`http://localhost:\d+/\S+`)
	err = b.SignUp(base, "check@example.com", func(email string) (string, error) {
		for _, m := range mail.Sent() {
			if m.To == email {
				return linkRE.FindString(m.Body), nil
			}
		}
		return "", errors.New("no email")
	})
	if err != nil {
		return fmt.Errorf("sign-up: %w", err)
	}

	step("pairing the pretend Mac")
	code, err := b.PairCode(base, "Pretend MacBook")
	if err != nil {
		return err
	}
	agent := testagent.New("ws"+strings.TrimPrefix(base, "http")+"/agent/v1", "")
	if agent.DeviceID, err = e2e.ExchangePairingCode(ctx, base, code, agent.PublicKeyDER(), "Pretend MacBook"); err != nil {
		return err
	}
	conn, err := agent.Dial(ctx)
	if err != nil {
		return err
	}

	step("approving a Claude Code client and getting its access token")
	token, err := b.Token(ctx, base)
	if err != nil {
		return err
	}
	cfg := filepath.Join(dir, "mcp.json")
	data, _ := json.Marshal(map[string]any{"mcpServers": map[string]any{
		"latchkey": map[string]any{"type": "http", "url": base + "/mcp", "headers": map[string]string{"Authorization": "Bearer " + token}},
	}})
	if err := os.WriteFile(cfg, data, 0o600); err != nil {
		return err
	}

	step("asking Claude Code for the battery")
	out, err := askClaude(ctx, model, cfg, "mcp__latchkey__battery_status",
		"Call the battery_status tool of the latchkey MCP server. Reply with only the battery percentage, as a number.")
	if err != nil {
		return err
	}
	if !strings.Contains(out, "82") {
		return fmt.Errorf("expected 82 in Claude's answer, got %q", out)
	}
	step("Claude answered %q", strings.TrimSpace(out))

	step("putting the pretend Mac to sleep for low battery")
	low := agent.State
	low.BatteryPercent, low.KeepAwake = 14, agentproto.KeepAwakeOffLowBattery
	_ = conn.Send(ctx, &agentproto.Goodbye{Reason: agentproto.ReasonLowBattery, State: low})
	_ = conn.Close()
	time.Sleep(500 * time.Millisecond)

	out, err = askClaude(ctx, model, cfg, "mcp__latchkey__battery_status",
		"Call the battery_status tool of the latchkey MCP server. Reply with the tool's text exactly as it was returned, nothing else.")
	if err != nil {
		return err
	}
	if !strings.Contains(out, "offline") || !strings.Contains(out, "14%") {
		return fmt.Errorf("expected the offline answer with 14%%, got %q", out)
	}
	step("Claude answered %q", strings.TrimSpace(out))
	return nil
}

func askClaude(ctx context.Context, model, cfg, tool, prompt string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "claude", "-p", prompt, //nolint:gosec // fixed program; arguments are ours
		"--model", model, "--mcp-config", cfg, "--strict-mcp-config",
		"--allowedTools", tool, "--output-format", "text")
	cmd.Dir = os.TempDir()
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("claude: %w: %s", err, out)
	}
	return string(out), nil
}

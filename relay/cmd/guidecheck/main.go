// Command guidecheck checks a relay set up by plugin/skills/set-up-latchkey/own-relay.md (spec 009 plan D8): it
// claims the fresh relay with its setup code in headless Chrome, pairs a pretend Mac, approves a
// client, and has real Claude Code call the Mac's battery tool through the relay. With
// -recovery-code it instead makes a new passkey with a code from the relay's operator command.
//
// The relay must accept a throwaway client (ALLOWED_CLIENT_HOSTS=*), as the check registers its
// own; Claude's own apps are on claude.ai and need no such setting.
//
//	go run ./cmd/guidecheck -relay https://192-0-2-10.sslip.io -setup-code K7PQ-M2XD-9RTA
//	go run ./cmd/guidecheck -relay https://192-0-2-10.sslip.io -recovery-code 123456
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/e2e"
	"github.com/tonimelisma/latchkey/relay/internal/testagent"
)

func main() {
	relay := flag.String("relay", "", "the relay's address, https://…")
	setupCode := flag.String("setup-code", "", "the relay's SETUP_CODE, to claim it")
	recovery := flag.String("recovery-code", "", "a code from `relay account recovery-code`, to recover instead")
	email := flag.String("email", "owner@example.com", "the account's email address")
	model := flag.String("model", "haiku", "Claude model for the check")
	flag.Parse()
	base := strings.TrimSuffix(*relay, "/")
	var err error
	switch {
	case !strings.HasPrefix(base, "https://"):
		err = errors.New("-relay must be an https:// address")
	case *recovery != "":
		err = recoverAccount(base, *email, *recovery)
	case *setupCode != "":
		err = claimAndUse(base, *email, *setupCode, *model)
	default:
		err = errors.New("give -setup-code or -recovery-code")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "FAIL:", err)
		os.Exit(1)
	}
	fmt.Println("PASS")
}

func step(format string, args ...any) { fmt.Printf("• "+format+"\n", args...) }

func claimAndUse(base, email, setupCode, model string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	b, err := e2e.NewBrowser(ctx)
	if err != nil {
		return fmt.Errorf("browser: %w", err)
	}
	defer b.Close()

	step("claiming the relay with its setup code in headless Chrome")
	if err := b.Claim(base, email, setupCode); err != nil {
		return fmt.Errorf("claim: %w", err)
	}

	step("pairing a pretend Mac")
	code, err := b.PairCode(base, "Pretend MacBook")
	if err != nil {
		return err
	}
	agent := testagent.New("wss"+strings.TrimPrefix(base, "https")+"/agent/v1", "")
	if agent.DeviceID, err = e2e.ExchangePairingCode(ctx, base, code, agent.PublicKeyDER(), "Pretend MacBook"); err != nil {
		return err
	}
	conn, err := agent.Dial(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close() }()

	step("approving a client and getting its access token")
	token, err := b.Token(ctx, base)
	if err != nil {
		return err
	}
	dir, err := os.MkdirTemp("", "latchkey-guidecheck-")
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(dir) }()
	cfg := filepath.Join(dir, "mcp.json")
	data, _ := json.Marshal(map[string]any{"mcpServers": map[string]any{
		"latchkey": map[string]any{"type": "http", "url": base + "/mcp", "headers": map[string]string{"Authorization": "Bearer " + token}},
	}})
	if err := os.WriteFile(cfg, data, 0o600); err != nil {
		return err
	}

	step("asking Claude Code for the battery through the relay")
	out, err := e2e.AskClaude(ctx, model, cfg, "mcp__latchkey__battery_status",
		"Call the battery_status tool of the latchkey MCP server. Reply with only the battery percentage, as a number.")
	if err != nil {
		return err
	}
	if !strings.Contains(out, "82") {
		return fmt.Errorf("expected 82 in Claude's answer, got %q", out)
	}
	step("Claude answered %q", strings.TrimSpace(out))
	return nil
}

func recoverAccount(base, email, code string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	b, err := e2e.NewBrowser(ctx)
	if err != nil {
		return fmt.Errorf("browser: %w", err)
	}
	defer b.Close()
	step("making a new passkey with the recovery code")
	b.SetEmail(email)
	return b.RecoverWithCode(base, code)
}

package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/tonimelisma/latchkey/relay/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/e2e"
	"github.com/tonimelisma/latchkey/relay/internal/e2erelay"
	"github.com/tonimelisma/latchkey/relay/internal/testagent"
)

// owner is a private relay with a signed-up account, a browser, and an access token for a
// client: what every check starts from.
type owner struct {
	relay   *e2erelay.Private
	browser *e2e.Browser
	email   string
	token   string
	dir     string
}

func newOwner(ctx context.Context, email string) (*owner, error) {
	dir, err := os.MkdirTemp("", "latchkey-e2e-")
	if err != nil {
		return nil, err
	}
	o := &owner{dir: dir, email: email}
	step("starting a private relay")
	if o.relay, err = e2erelay.StartPrivate(ctx, e2erelay.PrivateOptions{DBPath: filepath.Join(dir, "relay.db")}); err != nil {
		o.close()
		return nil, err
	}
	step("signing up in headless Chrome")
	if o.browser, err = e2e.NewBrowser(ctx); err != nil {
		o.close()
		return nil, fmt.Errorf("browser: %w", err)
	}
	if err := o.browser.SignUp(o.relay.Base, email, o.relay.CodeFor); err != nil {
		o.close()
		return nil, fmt.Errorf("sign-up: %w", err)
	}
	return o, nil
}

func (o *owner) approveClient(ctx context.Context) error {
	step("approving a client and getting its access token")
	t, err := o.browser.Token(ctx, o.relay.Base)
	o.token = t
	return err
}

func (o *owner) close() {
	if o.browser != nil {
		o.browser.Close()
	}
	if o.relay != nil {
		o.relay.Close()
	}
	_ = os.RemoveAll(o.dir)
}

func toolNames(tools []*mcp.Tool) []string {
	n := make([]string, len(tools))
	for i, t := range tools {
		n[i] = t.Name
	}
	return n
}

// relayCmd checks the relay's own surface end to end (FR-1501): the relay's tools listed,
// machines, a tool call reaching the machine, a capability turned off disappearing
// (Constitution III), and the offline answer arriving at once (Constitution II).
func relayCmd(args []string) error {
	fs := flag.NewFlagSet("relay", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	o, err := newOwner(ctx, "relay-check@example.com")
	if err != nil {
		return err
	}
	defer o.close()

	step("pairing a pretend Mac")
	code, err := o.browser.PairCode(o.relay.Base, "Pretend Mac")
	if err != nil {
		return err
	}
	agent := testagent.New("ws"+strings.TrimPrefix(o.relay.Base, "http")+"/agent/v1", "")
	if agent.DeviceID, err = e2e.ExchangePairingCode(ctx, o.relay.Base, code, agent.PublicKeyDER(), "Pretend Mac"); err != nil {
		return err
	}
	conn, err := agent.Dial(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close() }()
	if err := o.approveClient(ctx); err != nil {
		return err
	}
	cs, err := e2erelay.MCPClient(ctx, o.relay.Base, o.token, "e2e")
	if err != nil {
		return err
	}
	defer func() { _ = cs.Close() }()

	tools, err := e2erelay.ListAllTools(ctx, cs)
	if err != nil {
		return err
	}
	if !slices.Contains(toolNames(tools), "battery_status") {
		return fmt.Errorf("the pretend Mac's tool isn't listed: %v", toolNames(tools))
	}
	own := slices.DeleteFunc(slices.Clone(tools), func(t *mcp.Tool) bool { return t.Name == "battery_status" })
	step("the relay's own tools: %s", strings.Join(toolNames(own), ", "))

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "machines", Arguments: map[string]any{}})
	if err != nil {
		return err
	}
	if got := e2erelay.TextOf(res); res.IsError || !strings.Contains(got, "Pretend Mac") {
		return fmt.Errorf("machines didn't list the pretend Mac: %q", got)
	}
	step("machines lists the pretend Mac")

	res, err = cs.CallTool(ctx, &mcp.CallToolParams{Name: "battery_status", Arguments: map[string]any{}})
	if err != nil {
		return err
	}
	if got := e2erelay.TextOf(res); res.IsError || !strings.Contains(got, "82") {
		return fmt.Errorf("battery_status through the relay: %q", got)
	}
	step("a tool call reached the machine and came back")

	if err := conn.Send(ctx, &agentproto.ToolsUpdate{Tools: nil}); err != nil {
		return err
	}
	if !waitFor(10*time.Second, func() bool {
		t, err := e2erelay.ListAllTools(ctx, cs)
		return err == nil && !slices.Contains(toolNames(t), "battery_status")
	}) {
		return errors.New("battery_status still listed after the machine turned it off (Constitution III)")
	}
	step("a capability turned off on the machine disappeared from the list")

	if err := conn.Send(ctx, &agentproto.ToolsUpdate{Tools: []*mcp.Tool{testagent.BatteryStatusTool()}}); err != nil {
		return err
	}
	if !waitFor(10*time.Second, func() bool {
		t, err := e2erelay.ListAllTools(ctx, cs)
		return err == nil && slices.Contains(toolNames(t), "battery_status")
	}) {
		return errors.New("battery_status didn't come back when turned on again")
	}
	_ = conn.Send(ctx, &agentproto.Goodbye{Reason: agentproto.ReasonUserQuit, State: agent.State})
	_ = conn.Close()
	time.Sleep(300 * time.Millisecond)
	start := time.Now()
	res, err = cs.CallTool(ctx, &mcp.CallToolParams{Name: "battery_status", Arguments: map[string]any{}})
	if err != nil {
		return err
	}
	took := time.Since(start)
	if got := e2erelay.TextOf(res); !strings.Contains(strings.ToLower(got), "offline") {
		return fmt.Errorf("expected the offline answer, got %q", got)
	}
	if took > 5*time.Second {
		return fmt.Errorf("the offline answer took %s (Constitution II)", took.Round(time.Millisecond))
	}
	step("the offline answer came in %s", took.Round(time.Millisecond))
	fmt.Println("PASS: relay")
	return nil
}

func waitFor(within time.Duration, ok func() bool) bool {
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		if ok() {
			return true
		}
		time.Sleep(200 * time.Millisecond)
	}
	return false
}

// Package agent is the Linux program's connection to the relay (agent-protocol.md; spec 010 plan
// D8): it dials out only (Constitution I), signs the challenge, offers the tools the server's
// settings turn on, answers calls, sends its state every 15 seconds, follows setting changes at
// once, and reconnects on its own.
package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"reflect"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/tonimelisma/latchkey/linux/internal/activity"
	"github.com/tonimelisma/latchkey/linux/internal/config"
	"github.com/tonimelisma/latchkey/linux/internal/devicekey"
	"github.com/tonimelisma/latchkey/linux/internal/files"
	"github.com/tonimelisma/latchkey/linux/internal/shell"
	"github.com/tonimelisma/latchkey/linux/internal/tools"
	"github.com/tonimelisma/latchkey/relay/agentproto"
)

// Agent runs the connection.
type Agent struct {
	Paths   config.Paths
	Version string
	Logger  *slog.Logger
	Log     *activity.Log
	Shell   *shell.Shell
	Files   *files.Files
	// OnWelcome is called after each welcome (the updater marks a new version good).
	OnWelcome func()
	// Stopping reports whether the whole system is shutting down, for goodbye's reason.
	Stopping func() bool
	// SettingsEvery is how often settings.json is read again (default 1 s).
	SettingsEvery time.Duration

	mu       sync.Mutex
	settings config.Settings
	toolset  map[string]tools.Tool
	running  map[string]context.CancelFunc // call id → cancel
}

// ErrNotPaired: no device ID or key yet; `latchkey install` pairs.
var ErrNotPaired = errors.New("this server isn't paired yet; run latchkey install")

// closeError is how the relay ended a connection.
type closeError struct {
	code   websocket.StatusCode
	reason string
}

func (e closeError) Error() string {
	return fmt.Sprintf("closed by the relay (%d %s)", e.code, e.reason)
}

// Run keeps the server connected until ctx ends, then says goodbye.
func (a *Agent) Run(ctx context.Context) error {
	if a.SettingsEvery == 0 {
		a.SettingsEvery = time.Second
	}
	backoff := time.Second
	for ctx.Err() == nil {
		s, err := config.Load(a.Paths)
		if err == nil && s.DeviceID == "" {
			err = ErrNotPaired
		}
		var key *devicekey.Key
		if err == nil {
			key, err = devicekey.Load(a.Paths.Key)
		}
		if err != nil {
			a.Logger.Warn("not connecting", "err", err)
			if !sleep(ctx, 5*time.Second) {
				break
			}
			continue
		}
		start := time.Now()
		err = a.session(ctx, s, key)
		if ctx.Err() != nil {
			break
		}
		wait := backoff
		var ce closeError
		switch {
		case errors.As(err, &ce) && ce.code == agentproto.CloseRevoked:
			a.Log.Event("Removed from the account on the relay; the device key was deleted. Run latchkey install to pair again.")
			a.Logger.Warn("revoked by the relay: unpairing")
			_ = os.Remove(a.Paths.Key)
			if s2, err := config.Load(a.Paths); err == nil && s2.DeviceID == s.DeviceID {
				s2.DeviceID = ""
				_ = config.Save(a.Paths, s2)
			}
			a.Shell.StopAll("the server was removed from the account")
			continue
		case errors.As(err, &ce) && (ce.code == agentproto.CloseAuthFailed || ce.code == agentproto.CloseUnsupportedVersion):
			wait = 5 * time.Minute
		case errors.As(err, &ce) && ce.code == agentproto.CloseReplaced:
			wait = 30 * time.Second
		}
		if time.Since(start) > time.Minute { // it was up for a while: start the backoff again
			backoff, wait = time.Second, min(wait, time.Second)
		} else {
			backoff = min(backoff*2, time.Minute)
		}
		a.Logger.Info("disconnected", "err", err, "retry_in", wait)
		if !sleep(ctx, wait) {
			break
		}
	}
	a.Shell.Close()
	return nil
}

func sleep(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}

// agentURL is the relay's agent address for its https address.
func agentURL(relay string) (string, error) {
	u, err := url.Parse(strings.TrimRight(relay, "/"))
	if err != nil {
		return "", err
	}
	switch u.Scheme {
	case "https":
		u.Scheme = "wss"
	case "http":
		u.Scheme = "ws"
	default:
		return "", fmt.Errorf("the relay address must start with https://, not %q", relay)
	}
	u.Path += "/agent/v1"
	return u.String(), nil
}

// conn is one connection.
type conn struct {
	ws *websocket.Conn
	mu sync.Mutex // one writer at a time
}

func (c *conn) send(ctx context.Context, m agentproto.Message) error {
	data, err := agentproto.Encode(m)
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	return c.ws.Write(ctx, websocket.MessageText, data)
}

func (c *conn) read(ctx context.Context) (agentproto.Message, error) {
	_, data, err := c.ws.Read(ctx)
	if err != nil {
		if status := websocket.CloseStatus(err); status != -1 {
			var ce websocket.CloseError
			reason := ""
			if errors.As(err, &ce) {
				reason = ce.Reason
			}
			return nil, closeError{status, reason}
		}
		return nil, err
	}
	return agentproto.Decode(data)
}

// session is one connection from dial to its end.
func (a *Agent) session(ctx context.Context, s config.Settings, key *devicekey.Key) error {
	target, err := agentURL(s.Relay)
	if err != nil {
		return err
	}
	dialCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	ws, _, err := websocket.Dial(dialCtx, target, &websocket.DialOptions{Subprotocols: []string{agentproto.Subprotocol}})
	cancel()
	if err != nil {
		return err
	}
	ws.SetReadLimit(agentproto.MaxFrameBytes)
	c := &conn{ws: ws}
	defer func() { _ = ws.CloseNow() }()

	hsCtx, hsCancel := context.WithTimeout(ctx, 15*time.Second)
	defer hsCancel()
	msg, err := c.read(hsCtx)
	if err != nil {
		return err
	}
	challenge, ok := msg.(*agentproto.Challenge)
	if !ok {
		return fmt.Errorf("expected challenge, got %s", msg.MessageType())
	}
	sig, err := key.Sign(challenge.Nonce, s.DeviceID)
	if err != nil {
		return err
	}
	toolset := a.toolsFor(s)
	if err := c.send(hsCtx, &agentproto.Hello{
		DeviceID: s.DeviceID, Signature: sig, AppVersion: a.Version, OSVersion: osVersion(),
		Kind: agentproto.KindLinux, Name: s.MachineName(), Tools: defs(toolset), State: state(),
		Features: []string{agentproto.FeatureAudit},
	}); err != nil {
		return err
	}
	msg, err = c.read(hsCtx)
	if err != nil {
		return err
	}
	welcome, ok := msg.(*agentproto.Welcome)
	if !ok {
		return fmt.Errorf("expected welcome, got %s", msg.MessageType())
	}
	a.mu.Lock()
	a.settings, a.toolset, a.running = s, toolset, map[string]context.CancelFunc{}
	enableShell(a.Shell, s)
	a.mu.Unlock()
	name := s.MachineName()
	if welcome.Name != "" {
		name = welcome.Name
	}
	a.Logger.Info("connected", "relay", s.Relay, "name", name)
	a.Log.Event("Connected to %s as %q", s.Relay, name)
	if a.OnWelcome != nil {
		a.OnWelcome()
	}

	sessCtx, stop := context.WithCancel(ctx)
	defer stop()
	errs := make(chan error, 3)
	audits := make(chan *agentproto.Audit, 4)
	go func() { errs <- a.readLoop(sessCtx, c, audits) }()
	go func() { errs <- a.heartbeat(sessCtx, c, time.Duration(welcome.HeartbeatIntervalS)*time.Second) }()
	go func() { errs <- a.watchSettings(sessCtx, c) }()
	go a.auditCheck(sessCtx, c, audits)

	select {
	case err = <-errs:
	case <-ctx.Done():
		reason := agentproto.ReasonUserQuit
		if a.Stopping != nil && a.Stopping() {
			reason = agentproto.ReasonSystemShutdown
		}
		_ = c.send(context.Background(), &agentproto.Goodbye{Reason: reason, State: state()})
		_ = ws.Close(websocket.StatusNormalClosure, "")
		err = ctx.Err()
	}
	a.cancelAll()
	return err
}

// toolsFor is the toolset the settings turn on; paused changes nothing here (calls are answered
// "paused" instead, as the Mac's Pause).
func (a *Agent) toolsFor(s config.Settings) map[string]tools.Tool {
	out := map[string]tools.Tool{}
	var list []tools.Tool
	if s.Shell == config.On {
		list = append(list, a.Shell.Tools()...)
	}
	list = append(list, a.Files.Tools(s.Files)...)
	for _, t := range list {
		out[t.Def.Name] = t
	}
	return out
}

func defs(toolset map[string]tools.Tool) []*mcp.Tool {
	out := make([]*mcp.Tool, 0, len(toolset))
	for _, name := range sortedKeys(toolset) {
		out = append(out, toolset[name].Def)
	}
	return out
}

func sortedKeys(m map[string]tools.Tool) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	for i := range keys { // tiny lists: insertion sort keeps this dependency-free
		for j := i; j > 0 && keys[j] < keys[j-1]; j-- {
			keys[j], keys[j-1] = keys[j-1], keys[j]
		}
	}
	return keys
}

func (a *Agent) readLoop(ctx context.Context, c *conn, audits chan<- *agentproto.Audit) error {
	for {
		msg, err := c.read(ctx)
		if err != nil {
			return err
		}
		switch m := msg.(type) {
		case *agentproto.Call:
			go a.call(ctx, c, m)
		case *agentproto.Cancel:
			a.mu.Lock()
			cancel := a.running[m.ID]
			a.mu.Unlock()
			if cancel != nil {
				cancel()
			}
		case *agentproto.Audit:
			select {
			case audits <- m:
			default:
			}
		case *agentproto.Notice, *agentproto.Clients:
			// A server shows no notices and lists no apps; the relay doesn't send them to it.
		default:
			return fmt.Errorf("unexpected %s from the relay", msg.MessageType())
		}
	}
}

// call runs one tool call and answers it.
func (a *Agent) call(ctx context.Context, c *conn, m *agentproto.Call) {
	start := time.Now()
	deadline := time.Duration(m.DeadlineMS) * time.Millisecond
	if deadline <= 0 {
		deadline = agentproto.DefaultDeadline
	}
	callCtx, cancel := context.WithTimeout(ctx, deadline)
	defer cancel()
	a.mu.Lock()
	a.running[m.ID] = cancel
	s := a.settings
	tool, ok := a.toolset[m.Tool]
	a.mu.Unlock()
	defer func() {
		a.mu.Lock()
		delete(a.running, m.ID)
		a.mu.Unlock()
	}()

	var res tools.Result
	switch {
	case s.Paused:
		res = tools.Failf("The server's owner paused Claude's access to this server (latchkey resume turns it back on).")
	case !ok:
		res = tools.Failf("%s isn't turned on on this server.", m.Tool)
	default:
		res = run(callCtx, tool, m.Arguments)
	}
	if footer := a.Shell.Footer(); footer != "" { // every answer names running and kept commands (FR-322's rule)
		res.Content = append(res.Content, tools.Content{"type": "text", "text": "\n" + footer})
	}
	if err := c.send(ctx, res.Encode(m.ID)); err != nil {
		a.Logger.Warn("result not sent", "call", m.ID, "err", err)
	}
	_ = a.Log.Add(activity.Entry{
		Kind: "call", CallID: m.ID, Tool: m.Tool, Client: m.Client, Arguments: string(m.Arguments),
		Result: resultText(res), IsError: res.IsError, DurationMS: time.Since(start).Milliseconds(),
	})
}

// run runs a tool, turning a panic into an error answer (security review, 2026-10-31).
func run(ctx context.Context, t tools.Tool, raw json.RawMessage) (res tools.Result) {
	defer func() {
		if p := recover(); p != nil {
			res = tools.Failf("%s failed unexpectedly: %v", t.Def.Name, p)
		}
	}()
	args, err := tools.ParseArgs(raw)
	if err != nil {
		return tools.Failf("%v", err)
	}
	return t.Run(ctx, args)
}

func resultText(r tools.Result) string {
	var b strings.Builder
	for _, c := range r.Content {
		switch c["type"] {
		case "text":
			s, _ := c["text"].(string)
			b.WriteString(s)
		case "image":
			b.WriteString("[image]")
		}
	}
	return b.String()
}

func (a *Agent) cancelAll() {
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, cancel := range a.running {
		cancel()
	}
}

func (a *Agent) heartbeat(ctx context.Context, c *conn, every time.Duration) error {
	if every <= 0 {
		every = 15 * time.Second
	}
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-t.C:
			if err := c.send(ctx, &agentproto.StateUpdate{State: state()}); err != nil {
				return err
			}
		}
	}
}

// enableShell sets Shell's own switch from the settings.
func enableShell(sh *shell.Shell, s config.Settings) {
	sh.SetEnabled(s.Shell == config.On && !s.Paused, shellOffReason(s))
}

func shellOffReason(s config.Settings) string {
	if s.Paused {
		return "the server's owner paused Claude's access"
	}
	return "the server's owner turned Shell off"
}

// errReconnect ends a session so the next hello carries a new name.
var errReconnect = errors.New("the name changed: reconnecting")

// watchSettings follows settings.json: new levels change the tool list at once, Shell off or
// pause stops running commands (FR-310's rule), a new name reconnects.
func (a *Agent) watchSettings(ctx context.Context, c *conn) error {
	t := time.NewTicker(a.SettingsEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-t.C:
		}
		s, err := config.Load(a.Paths)
		if err != nil {
			continue // a half-written or broken file: keep the settings in force
		}
		a.mu.Lock()
		old := a.settings
		a.mu.Unlock()
		if reflect.DeepEqual(s, old) {
			continue
		}
		if s.DeviceID != old.DeviceID || s.Relay != old.Relay || s.MachineName() != old.MachineName() {
			return errReconnect
		}
		enableShell(a.Shell, s) // first refuse new commands, then stop the running ones
		if (old.Shell == config.On && s.Shell != config.On) || (!old.Paused && s.Paused) {
			a.Shell.StopAll(shellOffReason(s))
		}
		toolset := a.toolsFor(s)
		a.mu.Lock()
		changed := !reflect.DeepEqual(defs(toolset), defs(a.toolset))
		a.settings, a.toolset = s, toolset
		a.mu.Unlock()
		if changed {
			a.Log.Event("Tools changed: shell %s, files %s", s.Shell, s.Files)
			if err := c.send(ctx, &agentproto.ToolsUpdate{Tools: defs(toolset)}); err != nil {
				return err
			}
		}
	}
}

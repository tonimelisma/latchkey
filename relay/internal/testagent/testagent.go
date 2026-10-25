// Package testagent is a pretend Mac: it speaks the agent protocol
// (specs/001-core/contracts/agent-protocol.md) so relay tests and local scripts can run
// without the Mac app. It can also misbehave on purpose.
package testagent

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
)

// Handler answers a call. Returning nil sends no result (the call never finishes). The context
// is cancelled when the relay sends cancel; a handler may ignore it to produce a late result.
type Handler func(ctx context.Context, call *agentproto.Call) *agentproto.Result

// Agent describes the pretend Mac.
type Agent struct {
	URL      string // ws://host/agent/v1
	DeviceID string
	Key      *ecdsa.PrivateKey
	Tools    []*mcp.Tool
	State    agentproto.State
	Handler  Handler

	// Features is announced in hello; nil means an app from before features existed.
	Features []string

	// Misbehavior for tests.
	NoSubprotocol bool   // dial without latchkey.v1
	BadSignature  bool   // sign with a different key
	SkipHello     bool   // never send hello
	NoHeartbeat   bool   // don't send state every heartbeat interval
	RawHello      []byte // send these bytes instead of a hello
}

// New returns an agent with a fresh P-256 key, the battery_status tool, and a plausible state.
func New(url, deviceID string) *Agent {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		panic(err)
	}
	tz := "America/Los_Angeles"
	lid := false
	remaining := 312
	return &Agent{
		URL: url, DeviceID: deviceID, Key: key,
		Tools: []*mcp.Tool{BatteryStatusTool()},
		State: agentproto.State{
			BatteryPercent: 82, PowerSource: agentproto.PowerBattery, TimeRemainingMin: &remaining,
			ThermalState: "nominal", LidClosed: &lid, TimeZone: &tz, KeepAwake: agentproto.KeepAwakeOn,
			ObservedAt: time.Now().UTC().Truncate(time.Second),
		},
		Handler: BatteryHandler(82),
	}
}

// PublicKeyDER is the agent's public key as the relay stores it.
func (a *Agent) PublicKeyDER() []byte {
	der, err := x509.MarshalPKIXPublicKey(&a.Key.PublicKey)
	if err != nil {
		panic(err)
	}
	return der
}

// BatteryStatusTool is the contract's battery_status tool.
func BatteryStatusTool() *mcp.Tool {
	return &mcp.Tool{
		Name:        "battery_status",
		Title:       "Battery status",
		Description: "Live battery level and power state of the user's Mac.",
		InputSchema: map[string]any{"type": "object", "properties": map[string]any{}, "additionalProperties": false},
		OutputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"battery_percent":    map[string]any{"type": "integer"},
				"charging":           map[string]any{"type": "boolean"},
				"power_source":       map[string]any{"type": "string", "enum": []any{"battery", "ac", "ups", "unknown"}},
				"time_remaining_min": map[string]any{"type": []any{"integer", "null"}},
			},
			"required": []any{"battery_percent", "charging", "power_source"},
		},
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true, OpenWorldHint: new(false)},
		Meta:        mcp.Meta{agentproto.DeadlineMetaKey: float64(5000)},
	}
}

// BatteryHandler answers battery_status with the given percentage.
func BatteryHandler(percent int) Handler {
	return func(_ context.Context, call *agentproto.Call) *agentproto.Result {
		body := fmt.Sprintf(`{"battery_percent":%d,"charging":false,"power_source":"battery","time_remaining_min":312}`, percent)
		text, _ := jsonString(body)
		return &agentproto.Result{
			ID:                call.ID,
			Content:           []byte(`[{"type":"text","text":` + text + `}]`),
			StructuredContent: []byte(body),
		}
	}
}

// Conn is a live connection.
type Conn struct {
	agent   *Agent
	ws      *websocket.Conn
	Welcome *agentproto.Welcome
	Calls   chan *agentproto.Call    // every call received
	Cancels chan *agentproto.Cancel  // every cancel received
	Notices chan *agentproto.Notice  // every notice received
	Clients chan *agentproto.Clients // every list of apps with access received

	mu      sync.Mutex
	running map[string]context.CancelFunc
	frozen  chan struct{}
	freeze  sync.Once
	done    chan struct{}
	err     error
}

// Dial connects and completes the handshake. A rejected handshake returns an error whose close
// code CloseCode reports.
func (a *Agent) Dial(ctx context.Context) (*Conn, error) {
	opts := &websocket.DialOptions{}
	if !a.NoSubprotocol {
		opts.Subprotocols = []string{agentproto.Subprotocol}
	}
	ws, _, err := websocket.Dial(ctx, a.URL, opts)
	if err != nil {
		return nil, err
	}
	ws.SetReadLimit(agentproto.MaxFrameBytes)
	c := &Conn{
		agent: a, ws: ws,
		Calls: make(chan *agentproto.Call, 100), Cancels: make(chan *agentproto.Cancel, 100),
		Notices: make(chan *agentproto.Notice, 100), Clients: make(chan *agentproto.Clients, 100),
		running: map[string]context.CancelFunc{}, frozen: make(chan struct{}), done: make(chan struct{}),
	}
	msg, err := c.read(ctx)
	if err != nil {
		return nil, err
	}
	challenge, ok := msg.(*agentproto.Challenge)
	if !ok {
		return nil, fmt.Errorf("expected challenge, got %s", msg.MessageType())
	}
	if !a.SkipHello {
		if err := c.sendHello(ctx, challenge.Nonce); err != nil {
			return nil, err
		}
	}
	msg, err = c.read(ctx)
	if err != nil {
		return nil, err
	}
	welcome, ok := msg.(*agentproto.Welcome)
	if !ok {
		return nil, fmt.Errorf("expected welcome, got %s", msg.MessageType())
	}
	c.Welcome = welcome
	go c.readLoop() //nolint:gosec // the connection outlives the dial context
	if !a.NoHeartbeat {
		go c.heartbeat(time.Duration(welcome.HeartbeatIntervalS) * time.Second) //nolint:gosec // as above
	}
	return c, nil
}

func (c *Conn) sendHello(ctx context.Context, nonce string) error {
	if c.agent.RawHello != nil {
		return c.ws.Write(ctx, websocket.MessageText, c.agent.RawHello)
	}
	key := c.agent.Key
	if c.agent.BadSignature {
		var err error
		if key, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader); err != nil {
			return err
		}
	}
	digest := sha256.Sum256(agentproto.SignatureInput(nonce, c.agent.DeviceID))
	der, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		return err
	}
	return c.Send(ctx, &agentproto.Hello{
		DeviceID: c.agent.DeviceID, Signature: base64.RawURLEncoding.EncodeToString(der),
		AppVersion: "0.1.0-test", OSVersion: "26.1", Tools: c.agent.Tools, State: c.agent.State,
		Features: c.agent.Features,
	})
}

func (c *Conn) read(ctx context.Context) (agentproto.Message, error) {
	_, data, err := c.ws.Read(ctx)
	if err != nil {
		return nil, err
	}
	return agentproto.Decode(data)
}

func (c *Conn) readLoop() {
	defer close(c.done)
	for {
		msg, err := c.read(context.Background())
		if err != nil {
			c.err = err
			return
		}
		select {
		case <-c.frozen:
			continue
		default:
		}
		switch m := msg.(type) {
		case *agentproto.Call:
			c.Calls <- m
			go c.handle(m)
		case *agentproto.Cancel:
			c.mu.Lock()
			if cancel := c.running[m.ID]; cancel != nil {
				cancel()
			}
			c.mu.Unlock()
			c.Cancels <- m
		case *agentproto.Notice:
			c.Notices <- m
		case *agentproto.Clients:
			if !slices.Contains(c.agent.Features, agentproto.FeatureClients) {
				// What the app up to 0.8.9 does with a message type it doesn't know.
				_ = c.ws.Close(agentproto.CloseProtocolViolation, "unknown message type")
				c.err = errors.New("received clients without announcing the feature")
				return
			}
			c.Clients <- m
		}
	}
}

func (c *Conn) handle(call *agentproto.Call) {
	if c.agent.Handler == nil {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	c.mu.Lock()
	c.running[call.ID] = cancel
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		delete(c.running, call.ID)
		c.mu.Unlock()
		cancel()
	}()
	if res := c.agent.Handler(ctx, call); res != nil {
		_ = c.Send(context.Background(), res)
	}
}

func (c *Conn) heartbeat(every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-c.done:
			return
		case <-c.frozen:
			return
		case <-t.C:
			_ = c.Send(context.Background(), &agentproto.StateUpdate{State: c.agent.State})
		}
	}
}

// Send writes a message.
func (c *Conn) Send(ctx context.Context, m agentproto.Message) error {
	data, err := agentproto.Encode(m)
	if err != nil {
		return err
	}
	return c.SendRaw(ctx, websocket.MessageText, data)
}

// SendRaw writes arbitrary bytes.
func (c *Conn) SendRaw(ctx context.Context, typ websocket.MessageType, data []byte) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return c.ws.Write(ctx, typ, data)
}

// Freeze simulates a hung Mac: no more heartbeats, results, or handling of incoming frames.
// The connection stays open.
func (c *Conn) Freeze() { c.freeze.Do(func() { close(c.frozen) }) }

// Agent is the pretend Mac this connection belongs to.
func (c *Conn) Agent() *Agent { return c.agent }

// Close closes normally.
func (c *Conn) Close() error { return c.ws.Close(websocket.StatusNormalClosure, "") }

// Wait blocks until the relay closes the connection and returns its close code (-1 if none).
func (c *Conn) Wait(ctx context.Context) (int, error) {
	select {
	case <-c.done:
		return CloseCode(c.err), nil
	case <-ctx.Done():
		return 0, ctx.Err()
	}
}

// CloseCode extracts the WebSocket close code from an error, or -1.
func CloseCode(err error) int {
	return int(websocket.CloseStatus(err))
}

// IsClosed reports whether err is a WebSocket close.
func IsClosed(err error) bool { return CloseCode(err) != -1 || errors.Is(err, context.Canceled) }

func jsonString(s string) (string, error) {
	b, err := json.Marshal(s)
	return string(b), err
}

// Package hub holds the live connections from Macs (plan D1, D3). It authenticates them, keeps
// their latest state in the store, forwards tool calls with deadlines, and never queues a call
// for later (FR-025).
package hub

import (
	"context"
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Call failures. All of them are answered to Claude as normal tool results.
var (
	ErrOffline      = errors.New("mac offline")
	ErrTimeout      = errors.New("mac did not answer before the deadline")
	ErrRevoked      = errors.New("mac revoked during the call")
	ErrDisconnected = errors.New("mac disconnected during the call")
)

// writeTimeout bounds every frame the relay writes, so a stuck socket never blocks a caller.
const writeTimeout = 5 * time.Second

// Config tunes the hub. Zero values take the contract's defaults.
type Config struct {
	HandshakeTimeout  time.Duration // hello must arrive within this; default 10 s
	HeartbeatInterval time.Duration // told to the agent in welcome; default 15 s
	OfflineAfter      time.Duration // silence that means offline; default 2 × heartbeat + 5 s
	PingInterval      time.Duration // WebSocket pings; default 15 s
	Now               func() time.Time
	Logger            *slog.Logger

	// OnToolsChanged is called when a user's Mac tool list may have changed.
	OnToolsChanged func(userID string)
	// NoticesOnConnect returns notices to send right after welcome. previous is the device's
	// previous connection time (zero if none).
	NoticesOnConnect func(ctx context.Context, d store.Device, previous time.Time) []*agentproto.Notice
}

// Hub is an http.Handler for /agent/v1.
type Hub struct {
	store *store.Store
	cfg   Config

	mu     sync.Mutex
	conns  map[string]*conn // device ID → live connection
	closed bool
}

// New creates a hub. Devices still marked online from before a restart are marked offline.
func New(st *store.Store, cfg Config) *Hub {
	if cfg.HandshakeTimeout == 0 {
		cfg.HandshakeTimeout = 10 * time.Second
	}
	if cfg.HeartbeatInterval == 0 {
		cfg.HeartbeatInterval = 15 * time.Second
	}
	if cfg.OfflineAfter == 0 {
		cfg.OfflineAfter = 2*cfg.HeartbeatInterval + 5*time.Second
	}
	if cfg.PingInterval == 0 {
		cfg.PingInterval = 15 * time.Second
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	if cfg.OnToolsChanged == nil {
		cfg.OnToolsChanged = func(string) {}
	}
	h := &Hub{store: st, cfg: cfg, conns: map[string]*conn{}}
	if err := st.MarkAllOffline(context.Background()); err != nil {
		cfg.Logger.Error("mark devices offline", "err", err)
	}
	return h
}

func (h *Hub) now() time.Time { return h.cfg.Now().UTC() }

// Online reports whether the device has a live connection.
func (h *Hub) Online(deviceID string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	_, ok := h.conns[deviceID]
	return ok
}

func (h *Hub) conn(deviceID string) *conn {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.conns[deviceID]
}

// Call forwards a tool call to the device and waits for its result, at most until deadline.
// progress, if not nil, receives progress messages.
func (h *Hub) Call(ctx context.Context, deviceID, tool string, args json.RawMessage, deadline time.Duration,
	progress func(*agentproto.Progress),
) (*agentproto.Result, error) {
	c := h.conn(deviceID)
	if c == nil {
		return nil, ErrOffline
	}
	return c.call(ctx, tool, args, deadline, progress)
}

// Revoke closes the device's connection with 4002; in-flight calls fail with ErrRevoked.
// The caller has already revoked the device in the store.
func (h *Hub) Revoke(deviceID string) {
	if c := h.conn(deviceID); c != nil {
		c.closeWith(ErrRevoked, agentproto.CloseRevoked, "device revoked")
	}
}

// SendNotice delivers a notice to an online device.
func (h *Hub) SendNotice(ctx context.Context, deviceID string, n *agentproto.Notice) error {
	c := h.conn(deviceID)
	if c == nil {
		return ErrOffline
	}
	return c.send(ctx, n)
}

// Close disconnects every device (normal closure, so they reconnect) and marks them offline.
func (h *Hub) Close() {
	h.mu.Lock()
	h.closed = true
	conns := make([]*conn, 0, len(h.conns))
	for _, c := range h.conns {
		conns = append(conns, c)
	}
	h.mu.Unlock()
	for _, c := range conns {
		c.closeWith(ErrDisconnected, agentproto.CloseNormal, "relay shutting down")
		<-c.done
	}
}

// ServeHTTP accepts an agent WebSocket.
func (h *Hub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{agentproto.Subprotocol}})
	if err != nil {
		return // Accept already wrote the HTTP error
	}
	ws.SetReadLimit(agentproto.MaxFrameBytes)
	if ws.Subprotocol() != agentproto.Subprotocol {
		_ = ws.Close(agentproto.CloseUnsupportedVersion, "subprotocol "+agentproto.Subprotocol+" required")
		return
	}
	ctx := r.Context()
	device, hello, err := h.handshake(ctx, ws)
	if err != nil {
		var ce closeError
		switch {
		case errors.As(err, &ce):
			_ = ws.Close(ce.code, ce.reason)
		case errors.Is(err, errHandshakeTimedOut):
			// already closed with 4006
		default:
			_ = ws.CloseNow()
		}
		return
	}
	c := h.newConn(ws, device)
	if !h.start(ctx, c, hello) {
		return
	}
	c.run(ctx)
	h.finish(c)
}

var errHandshakeTimedOut = errors.New("handshake timed out")

type closeError struct {
	code   websocket.StatusCode
	reason string
}

func (e closeError) Error() string { return fmt.Sprintf("close %d: %s", e.code, e.reason) }

func violation(err error) closeError {
	return closeError{agentproto.CloseProtocolViolation, truncate(err.Error())}
}

// truncate keeps a close reason within the WebSocket limit of 123 bytes.
func truncate(s string) string {
	if len(s) > 120 {
		return s[:120]
	}
	return s
}

func (h *Hub) handshake(ctx context.Context, ws *websocket.Conn) (store.Device, *agentproto.Hello, error) {
	nonce, err := agentproto.NewNonce()
	if err != nil {
		return store.Device{}, nil, err
	}
	if err := write(ctx, ws, &agentproto.Challenge{Nonce: nonce, ServerTime: h.now().Truncate(time.Second)}); err != nil {
		return store.Device{}, nil, err
	}
	// A timed-out Read would drop the socket without a close code, so a timer closes it with 4006.
	timer := time.AfterFunc(h.cfg.HandshakeTimeout, func() {
		_ = ws.Close(agentproto.CloseHandshakeTimeout, "no hello in time")
	})
	typ, data, err := ws.Read(ctx)
	if !timer.Stop() {
		return store.Device{}, nil, errHandshakeTimedOut
	}
	switch {
	case err != nil:
		return store.Device{}, nil, err
	case typ != websocket.MessageText:
		return store.Device{}, nil, violation(errors.New("text frames only"))
	}
	msg, err := agentproto.Decode(data)
	if err != nil {
		return store.Device{}, nil, violation(err)
	}
	hello, ok := msg.(*agentproto.Hello)
	if !ok {
		return store.Device{}, nil, violation(fmt.Errorf("expected hello, got %s", msg.MessageType()))
	}
	authFailed := closeError{agentproto.CloseAuthFailed, "authentication failed"}
	device, err := h.store.Device(ctx, hello.DeviceID)
	if err != nil || device.PublicKey == nil {
		return store.Device{}, nil, authFailed
	}
	pub, err := x509.ParsePKIXPublicKey(device.PublicKey)
	if err != nil {
		return store.Device{}, nil, authFailed
	}
	ecPub, ok := pub.(*ecdsa.PublicKey)
	if !ok || agentproto.VerifySignature(ecPub, nonce, hello.DeviceID, hello.Signature) != nil {
		return store.Device{}, nil, authFailed
	}
	return device, hello, nil
}

// start registers the connection, replacing an older one, and sends welcome and notices.
func (h *Hub) start(ctx context.Context, c *conn, hello *agentproto.Hello) bool {
	previous, err := h.store.DeviceState(ctx, c.device.ID)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		h.cfg.Logger.Error("read device state", "device", c.device.ID, "err", err)
	}
	if err := h.store.UpdateDeviceVersions(ctx, c.device.ID, hello.AppVersion, hello.OSVersion); err != nil {
		h.cfg.Logger.Error("update device versions", "device", c.device.ID, "err", err)
	}
	now := h.now()
	c.state = store.DeviceState{DeviceID: c.device.ID, Online: true, ConnectedAt: now, LastSeenAt: now}
	c.setState(hello.State)
	c.setTools(hello.Tools)

	err = write(ctx, c.ws, &agentproto.Welcome{
		HeartbeatIntervalS: int(h.cfg.HeartbeatInterval / time.Second), ServerTime: now.Truncate(time.Second),
	})
	if err != nil {
		_ = c.ws.CloseNow()
		return false
	}

	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		_ = c.ws.Close(agentproto.CloseNormal, "relay shutting down")
		return false
	}
	old := h.conns[c.device.ID]
	h.conns[c.device.ID] = c
	h.mu.Unlock()
	if old != nil {
		old.closeWith(ErrDisconnected, agentproto.CloseReplaced, "replaced by a newer connection")
	}

	c.persist(ctx)
	h.cfg.OnToolsChanged(c.device.UserID)
	if h.cfg.NoticesOnConnect != nil {
		for _, n := range h.cfg.NoticesOnConnect(ctx, c.device, previous.ConnectedAt) {
			if err := c.send(ctx, n); err != nil {
				h.cfg.Logger.Warn("send notice", "device", c.device.ID, "err", err)
			}
		}
	}
	return true
}

// finish records the connection offline and unregisters it, unless a newer one replaced it.
// The store is written under the hub lock so it never shows an older connection's state.
func (h *Hub) finish(c *conn) {
	c.failPending()
	c.mu.Lock()
	c.state.Online = false
	revoked := errors.Is(c.closeErr, ErrRevoked)
	c.mu.Unlock()

	h.mu.Lock()
	current := h.conns[c.device.ID] == c
	if current {
		if !revoked { // a revoked device's state no longer matters
			c.persist(context.Background())
		}
		delete(h.conns, c.device.ID)
	}
	h.mu.Unlock()
	if current && revoked {
		h.cfg.OnToolsChanged(c.device.UserID)
	}
}

func write(ctx context.Context, ws *websocket.Conn, m agentproto.Message) error {
	data, err := agentproto.Encode(m)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, writeTimeout)
	defer cancel()
	return ws.Write(ctx, websocket.MessageText, data)
}

type pendingCall struct {
	result   chan *agentproto.Result
	progress func(*agentproto.Progress)
}

type conn struct {
	hub    *Hub
	ws     *websocket.Conn
	device store.Device
	nextID atomic.Uint64
	done   chan struct{}

	mu       sync.Mutex
	pending  map[string]*pendingCall
	state    store.DeviceState
	closeErr error // why calls fail once closed
	finished bool
}

func (h *Hub) newConn(ws *websocket.Conn, d store.Device) *conn {
	return &conn{hub: h, ws: ws, device: d, done: make(chan struct{}), pending: map[string]*pendingCall{}}
}

func (c *conn) send(ctx context.Context, m agentproto.Message) error { return write(ctx, c.ws, m) }

// closeWith closes the socket; the first reason given wins.
func (c *conn) closeWith(reason error, code websocket.StatusCode, text string) {
	c.mu.Lock()
	if c.closeErr == nil {
		c.closeErr = reason
	}
	c.mu.Unlock()
	go func() { _ = c.ws.Close(code, text) }()
}

func (c *conn) setState(s agentproto.State) {
	data, err := json.Marshal(s)
	if err != nil {
		return
	}
	c.mu.Lock()
	c.state.StateJSON = data
	c.mu.Unlock()
}

func (c *conn) setTools(tools []*mcp.Tool) {
	if tools == nil {
		tools = []*mcp.Tool{}
	}
	data, err := json.Marshal(tools)
	if err != nil {
		return
	}
	c.mu.Lock()
	c.state.ToolsJSON = data
	c.mu.Unlock()
}

func (c *conn) persist(ctx context.Context) {
	c.mu.Lock()
	st := c.state
	c.mu.Unlock()
	if err := c.hub.store.PutDeviceState(ctx, st); err != nil {
		c.hub.cfg.Logger.Error("store device state", "device", c.device.ID, "err", err)
	}
}

// run reads frames until the connection ends. Silence longer than OfflineAfter ends it.
func (c *conn) run(ctx context.Context) {
	defer close(c.done)
	pingCtx, stopPing := context.WithCancel(ctx)
	defer stopPing()
	go c.ping(pingCtx)
	for {
		rctx, cancel := context.WithTimeout(ctx, c.hub.cfg.OfflineAfter)
		typ, data, err := c.ws.Read(rctx)
		cancel()
		if err != nil {
			return // closed, timed out (the library closes the socket), or too big (1009)
		}
		now := c.hub.now()
		c.mu.Lock()
		c.state.LastSeenAt = now
		c.mu.Unlock()
		if typ != websocket.MessageText {
			c.closeWith(ErrDisconnected, agentproto.CloseProtocolViolation, "text frames only")
			return
		}
		msg, err := agentproto.Decode(data)
		if err != nil {
			c.closeWith(ErrDisconnected, agentproto.CloseProtocolViolation, truncate(err.Error()))
			return
		}
		if !c.handle(ctx, msg) {
			return
		}
	}
}

func (c *conn) handle(ctx context.Context, msg agentproto.Message) bool {
	switch m := msg.(type) {
	case *agentproto.StateUpdate:
		c.setState(m.State)
		c.persist(ctx)
	case *agentproto.ToolsUpdate:
		c.setTools(m.Tools)
		c.persist(ctx)
		c.hub.cfg.OnToolsChanged(c.device.UserID)
	case *agentproto.Progress:
		c.mu.Lock()
		p := c.pending[m.ID]
		c.mu.Unlock()
		if p != nil && p.progress != nil {
			p.progress(m)
		}
	case *agentproto.Result:
		c.mu.Lock()
		p := c.pending[m.ID]
		delete(c.pending, m.ID)
		c.mu.Unlock()
		if p != nil {
			p.result <- m // buffered; unknown or cancelled IDs are ignored
		}
	case *agentproto.Goodbye:
		c.setState(m.State)
		c.mu.Lock()
		c.state.OfflineReason = m.Reason
		c.mu.Unlock()
		if m.Reason == agentproto.ReasonUserDisconnected {
			if err := c.hub.store.RevokeDevice(ctx, c.device.ID, c.hub.now()); err != nil {
				c.hub.cfg.Logger.Error("revoke device", "device", c.device.ID, "err", err)
			}
			c.closeWith(ErrRevoked, agentproto.CloseRevoked, "device revoked")
			return false
		}
		c.persist(ctx)
	default:
		c.closeWith(ErrDisconnected, agentproto.CloseProtocolViolation,
			fmt.Sprintf("%s is not an agent message", msg.MessageType()))
		return false
	}
	// A new frame after a goodbye means the Mac is still here.
	if _, ok := msg.(*agentproto.Goodbye); !ok {
		c.mu.Lock()
		c.state.OfflineReason = ""
		c.mu.Unlock()
	}
	return true
}

func (c *conn) ping(ctx context.Context) {
	t := time.NewTicker(c.hub.cfg.PingInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			pctx, cancel := context.WithTimeout(ctx, c.hub.cfg.PingInterval)
			_ = c.ws.Ping(pctx) // liveness is judged by frames, not pongs
			cancel()
		}
	}
}

func (c *conn) failPending() {
	c.mu.Lock()
	c.finished = true
	if c.closeErr == nil {
		c.closeErr = ErrDisconnected
	}
	c.pending = map[string]*pendingCall{}
	c.mu.Unlock()
}

func (c *conn) call(ctx context.Context, tool string, args json.RawMessage, deadline time.Duration,
	progress func(*agentproto.Progress),
) (*agentproto.Result, error) {
	if args == nil {
		args = json.RawMessage(`{}`)
	}
	id := "c_" + strconv.FormatUint(c.nextID.Add(1), 10)
	p := &pendingCall{result: make(chan *agentproto.Result, 1), progress: progress}
	c.mu.Lock()
	if c.finished {
		c.mu.Unlock()
		return nil, ErrDisconnected
	}
	c.pending[id] = p
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
	}()

	timer := time.NewTimer(deadline)
	defer timer.Stop()
	err := c.send(ctx, &agentproto.Call{ID: id, Tool: tool, Arguments: args, DeadlineMS: deadline.Milliseconds()})
	if err != nil {
		return nil, c.failure()
	}
	select {
	case res := <-p.result:
		return res, nil
	case <-timer.C:
		c.cancel(id, agentproto.CancelDeadline)
		return nil, ErrTimeout
	case <-ctx.Done():
		c.cancel(id, agentproto.CancelClientCancelled)
		return nil, ctx.Err()
	case <-c.done:
		return nil, c.failure()
	}
}

func (c *conn) failure() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closeErr != nil {
		return c.closeErr
	}
	return ErrDisconnected
}

func (c *conn) cancel(id, reason string) {
	go func() { _ = c.send(context.Background(), &agentproto.Cancel{ID: id, Reason: reason}) }()
}

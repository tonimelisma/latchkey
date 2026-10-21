// Package mcpserver is what Claude talks to (plan D2, contracts/mcp-surface.md): the MCP
// handshake, the tool list (laptop_status plus the Mac's last reported tools), laptop_status
// itself, and forwarding of Mac tool calls through the hub. Every call ends in a tool result;
// a Mac that cannot answer is explained in words, never a protocol error.
package mcpserver

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"reflect"
	"sync"
	"time"

	"github.com/modelcontextprotocol/go-sdk/auth"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/hub"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Options configures the server.
type Options struct {
	Now     func() time.Time
	Logger  *slog.Logger
	Version string // reported in serverInfo
}

// Server is an http.Handler for /mcp. It must sit behind auth.RequireBearerToken, whose
// TokenInfo.UserID names the Owner.
type Server struct {
	store     *store.Store
	hub       *hub.Hub
	opts      Options
	stateful  *mcp.StreamableHTTPHandler // 2025-11-25 and older: sessions, list_changed
	stateless *mcp.StreamableHTTPHandler // 2026-07-28 and newer

	mu    sync.Mutex
	users map[string]*userServer
}

// userServer is one Owner's MCP server; its tool list is that Owner's Mac tools.
type userServer struct {
	mu     sync.Mutex
	server *mcp.Server
	tools  map[string]*mcp.Tool // Mac tools currently registered
}

// New creates the server.
func New(st *store.Store, h *hub.Hub, opts Options) *Server {
	if opts.Now == nil {
		opts.Now = time.Now
	}
	if opts.Logger == nil {
		opts.Logger = slog.Default()
	}
	if opts.Version == "" {
		opts.Version = "dev"
	}
	s := &Server{store: st, hub: h, opts: opts, users: map[string]*userServer{}}
	sdkLog := sdkLogger(opts.Logger)
	s.stateful = mcp.NewStreamableHTTPHandler(s.serverFor, &mcp.StreamableHTTPOptions{Logger: sdkLog})
	s.stateless = mcp.NewStreamableHTTPHandler(s.serverFor, &mcp.StreamableHTTPOptions{Logger: sdkLog, Stateless: true})
	return s
}

// firstStatelessVersion is the first protocol version without sessions. The SDK serves it only
// from a stateless handler, while Claude's hosted client still uses 2025-11-25 sessions, so
// requests are routed by the version header that newer clients send on every request.
const firstStatelessVersion = "2026-07-28"

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if v := r.Header.Get("MCP-Protocol-Version"); v >= firstStatelessVersion {
		s.stateless.ServeHTTP(w, r)
		return
	}
	s.stateful.ServeHTTP(w, r)
}

// sdkLogger keeps the SDK's per-session INFO lines out of the relay log.
func sdkLogger(l *slog.Logger) *slog.Logger {
	return slog.New(levelFilter{l.Handler(), slog.LevelWarn})
}

type levelFilter struct {
	slog.Handler
	min slog.Level
}

func (f levelFilter) Enabled(ctx context.Context, l slog.Level) bool {
	return l >= f.min && f.Handler.Enabled(ctx, l)
}

func (f levelFilter) WithAttrs(a []slog.Attr) slog.Handler {
	return levelFilter{f.Handler.WithAttrs(a), f.min}
}

func (f levelFilter) WithGroup(n string) slog.Handler {
	return levelFilter{f.Handler.WithGroup(n), f.min}
}

func userID(r *http.Request) string {
	if info := auth.TokenInfoFromContext(r.Context()); info != nil {
		return info.UserID
	}
	return ""
}

func (s *Server) serverFor(r *http.Request) *mcp.Server {
	id := userID(r)
	if id == "" {
		return nil
	}
	return s.user(r.Context(), id).server
}

func (s *Server) user(ctx context.Context, id string) *userServer {
	s.mu.Lock()
	u, ok := s.users[id]
	if !ok {
		u = &userServer{
			server: mcp.NewServer(&mcp.Implementation{Name: "latchkey", Title: "Latchkey", Version: s.opts.Version},
				&mcp.ServerOptions{Logger: s.opts.Logger}),
			tools: map[string]*mcp.Tool{},
		}
		u.server.AddTool(laptopStatusTool(), s.laptopStatus(id))
		s.users[id] = u
	}
	s.mu.Unlock()
	if !ok {
		s.syncTools(ctx, id, u)
	}
	return u
}

// ToolsChanged reloads the user's Mac tools from the store; connected sessions are notified
// with notifications/tools/list_changed (FR-062).
func (s *Server) ToolsChanged(userID string) {
	s.mu.Lock()
	u, ok := s.users[userID]
	s.mu.Unlock()
	if ok {
		s.syncTools(context.Background(), userID, u)
	}
}

func (s *Server) macTools(ctx context.Context, userID string) []*mcp.Tool {
	d, err := s.store.ActiveDevice(ctx, userID)
	if err != nil {
		return nil
	}
	st, err := s.store.DeviceState(ctx, d.ID)
	if err != nil || st.ToolsJSON == nil {
		return nil
	}
	var tools []*mcp.Tool
	if err := json.Unmarshal(st.ToolsJSON, &tools); err != nil {
		s.opts.Logger.Error("stored tools unreadable", "device", d.ID, "err", err)
		return nil
	}
	if agentproto.ValidateTools(tools) != nil {
		return nil // validated on arrival; never hand the SDK a tool it would panic on
	}
	return tools
}

func (s *Server) syncTools(ctx context.Context, userID string, u *userServer) {
	want := map[string]*mcp.Tool{}
	for _, t := range s.macTools(ctx, userID) {
		want[t.Name] = t
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	var gone []string
	for name := range u.tools {
		if _, ok := want[name]; !ok {
			gone = append(gone, name)
		}
	}
	if len(gone) > 0 {
		u.server.RemoveTools(gone...)
		for _, name := range gone {
			delete(u.tools, name)
		}
	}
	for name, t := range want {
		if old, ok := u.tools[name]; ok && reflect.DeepEqual(old, t) {
			continue
		}
		u.server.AddTool(t, s.forward(userID, t))
		u.tools[name] = t
	}
}

// status gathers what the relay knows about the user's Mac.
func (s *Server) status(ctx context.Context, userID string) (status, store.Device) {
	d, err := s.store.ActiveDevice(ctx, userID)
	if err != nil {
		return status{}, store.Device{}
	}
	st := status{Paired: true, Online: s.hub.Online(d.ID)}
	ds, err := s.store.DeviceState(ctx, d.ID)
	if err != nil {
		return st, d
	}
	st.LastSeen, st.OfflineReason = ds.LastSeenAt, ds.OfflineReason
	if ds.StateJSON != nil {
		var state agentproto.State
		if json.Unmarshal(ds.StateJSON, &state) == nil {
			st.State = &state
		}
	}
	return st, d
}

func laptopStatusTool() *mcp.Tool {
	return &mcp.Tool{
		Name:  agentproto.RelayToolLaptopStatus,
		Title: "Laptop status",
		Description: "Whether the user's Mac is online, when it was last seen, and its last known battery, " +
			"power, thermal and keep-awake state. Works even when the Mac is offline.",
		InputSchema: map[string]any{"type": "object", "properties": map[string]any{}, "additionalProperties": false},
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true, OpenWorldHint: new(false)},
	}
}

// laptopStatusResult is laptop_status's structured content.
type laptopStatusResult struct {
	Paired        bool              `json:"paired"`
	Online        bool              `json:"online"`
	LastSeen      *time.Time        `json:"last_seen"`
	OfflineReason *string           `json:"offline_reason"`
	State         *agentproto.State `json:"state"`
}

func (s *Server) laptopStatus(userID string) mcp.ToolHandler {
	return func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		start := s.opts.Now()
		st, d := s.status(ctx, userID)
		out := laptopStatusResult{Paired: st.Paired, Online: st.Online, State: st.State}
		if !st.LastSeen.IsZero() {
			out.LastSeen = &st.LastSeen
		}
		if st.OfflineReason != "" && !st.Online {
			out.OfflineReason = &st.OfflineReason
		}
		var msg string
		switch {
		case st.Online && st.State != nil:
			msg = onlineText(st.State)
		case st.Online:
			msg = "Your Mac is online."
		default:
			msg = offlineText(st, s.opts.Now())
		}
		s.audit(ctx, req, userID, d.ID, agentproto.RelayToolLaptopStatus, store.OutcomeOK, start)
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: msg}}, StructuredContent: out}, nil
	}
}

func errorResult(text string) *mcp.CallToolResult {
	return &mcp.CallToolResult{IsError: true, Content: []mcp.Content{&mcp.TextContent{Text: text}}}
}

// forward sends a Mac tool call through the hub. The hub bounds it by the tool's deadline.
func (s *Server) forward(userID string, tool *mcp.Tool) mcp.ToolHandler {
	deadline := agentproto.ToolDeadline(tool)
	return func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		start := s.opts.Now()
		st, d := s.status(ctx, userID)
		if !st.Paired {
			s.audit(ctx, req, userID, "", tool.Name, store.OutcomeOffline, start)
			return errorResult(neverPairedText), nil
		}
		res, err := s.hub.Call(ctx, d.ID, tool.Name, req.Params.Arguments, deadline, progressFunc(ctx, req))
		var result *mcp.CallToolResult
		outcome := store.OutcomeOK
		switch {
		case errors.Is(err, hub.ErrOffline):
			st, _ = s.status(ctx, userID) // re-read: the Mac may have just said goodbye
			result, outcome = errorResult(offlineText(st, s.opts.Now())), store.OutcomeOffline
		case errors.Is(err, hub.ErrTimeout):
			result, outcome = errorResult(timeoutText(deadline)), store.OutcomeTimeout
		case errors.Is(err, hub.ErrRevoked):
			result, outcome = errorResult(revokedText), store.OutcomeError
		case errors.Is(err, hub.ErrDisconnected):
			result, outcome = errorResult(disconnectedText), store.OutcomeError
		case err != nil: // the client went away
			result, outcome = errorResult("The request was cancelled."), store.OutcomeError
		default:
			result = toResult(res)
			if result.IsError {
				outcome = store.OutcomeError
			}
		}
		s.audit(ctx, req, userID, d.ID, tool.Name, outcome, start)
		return result, nil
	}
}

// toResult converts the Mac's result into an MCP result without interpreting it.
func toResult(res *agentproto.Result) *mcp.CallToolResult {
	raw := map[string]json.RawMessage{"content": res.Content}
	if res.StructuredContent != nil {
		raw["structuredContent"] = res.StructuredContent
	}
	data, err := json.Marshal(raw)
	var out mcp.CallToolResult
	if err == nil {
		err = json.Unmarshal(data, &out)
	}
	if err != nil || out.Content == nil {
		return errorResult("Your Mac sent a result the relay couldn't read.")
	}
	out.IsError = res.IsError
	return &out
}

func progressFunc(ctx context.Context, req *mcp.CallToolRequest) func(*agentproto.Progress) {
	token := req.Params.GetProgressToken()
	if token == nil {
		return nil
	}
	return func(p *agentproto.Progress) {
		params := &mcp.ProgressNotificationParams{ProgressToken: token, Progress: p.Progress, Message: p.Message}
		if p.Total != nil {
			params.Total = *p.Total
		}
		_ = req.Session.NotifyProgress(ctx, params)
	}
}

func (s *Server) audit(ctx context.Context, req *mcp.CallToolRequest, userID, deviceID, tool, outcome string, start time.Time) {
	surface := ""
	if info := req.ClientInfo(); info != nil {
		surface = info.Name
	}
	err := s.store.AddAudit(ctx, store.AuditEntry{
		UserID: userID, DeviceID: deviceID, At: start.UTC(), Tool: tool, Surface: surface,
		Outcome: outcome, Duration: s.opts.Now().Sub(start),
	})
	if err != nil {
		s.opts.Logger.Error("audit", "err", err)
	}
}

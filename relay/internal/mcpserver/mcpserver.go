// Package mcpserver is what Claude talks to (plan D2, contracts/mcp-surface.md): the MCP
// handshake, the tool list (the Mac's last reported tools), and forwarding of Mac tool calls
// through the hub. Every call ends in a tool result; a Mac that cannot answer is explained in
// words, never a protocol error, and every answer carries the Mac's state (FR-065).
package mcpserver

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"reflect"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

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
	// SessionTimeout closes a 2025-11-25 session that received no request for this long.
	// Default DefaultSessionTimeout.
	SessionTimeout time.Duration
}

// DefaultSessionTimeout is how long an unused session lives (FR-090).
const DefaultSessionTimeout = 30 * time.Minute

// MaxSessionsPerUser is how many sessions one Owner may hold; one more closes the oldest
// (FR-090). Claude opens a session per conversation at most, and they expire when idle.
const MaxSessionsPerUser = 64

// Users is how many Owners have a server in memory.
func (s *Server) Users() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.users)
}

// Forget drops the Owner's server and closes its sessions: called when the account is deleted or
// Claude's access is removed, so neither leaves anything in memory (FR-090). A later sign-in
// simply builds a new server.
func (s *Server) Forget(userID string) {
	s.mu.Lock()
	u := s.users[userID]
	delete(s.users, userID)
	s.mu.Unlock()
	if u == nil {
		return
	}
	for ss := range u.server.Sessions() {
		_ = ss.Close()
	}
}

// GrantExtra is the key in auth.TokenInfo.Extra under which the bearer check names the grant
// (the Owner's approval of one app) a request belongs to. The same string as oauth.GrantExtra;
// a test in the server package keeps them equal.
const GrantExtra = "latchkey_grant"

func grantID(r *http.Request) string {
	if info := auth.TokenInfoFromContext(r.Context()); info != nil {
		id, _ := info.Extra[GrantExtra].(string)
		return id
	}
	return ""
}

// ForgetGrant closes the sessions that one of the Owner's apps opened: called when that app's
// access is removed while others keep theirs (FR-191). The Owner's server and every other
// session stay.
func (s *Server) ForgetGrant(userID, grant string) {
	s.mu.Lock()
	u := s.users[userID]
	s.mu.Unlock()
	if u == nil || grant == "" {
		return
	}
	u.mu.Lock()
	var ids []string
	for id, g := range u.grants {
		if g == grant {
			ids = append(ids, id)
			delete(u.grants, id)
		}
	}
	u.mu.Unlock()
	for ss := range u.server.Sessions() {
		if slices.Contains(ids, ss.ID()) {
			_ = ss.Close()
		}
	}
}

// noteSession remembers which grant opened a session, and forgets sessions that have ended.
func (s *Server) noteSession(userID, sessionID, grant string) {
	s.mu.Lock()
	u := s.users[userID]
	s.mu.Unlock()
	if u == nil {
		return
	}
	live := map[string]bool{}
	for ss := range u.server.Sessions() {
		live[ss.ID()] = true
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	for id := range u.grants {
		if !live[id] {
			delete(u.grants, id)
		}
	}
	u.grants[sessionID] = grant
}

// sessionWriter watches for the session ID the SDK assigns in answer to a request that opens a
// session.
type sessionWriter struct {
	http.ResponseWriter
	seen func(sessionID string)
	done bool
}

func (w *sessionWriter) note() {
	if w.done {
		return
	}
	w.done = true
	if id := w.Header().Get("Mcp-Session-Id"); id != "" {
		w.seen(id)
	}
}

func (w *sessionWriter) WriteHeader(code int) {
	w.note()
	w.ResponseWriter.WriteHeader(code)
}

func (w *sessionWriter) Write(b []byte) (int, error) {
	w.note()
	return w.ResponseWriter.Write(b)
}

// Flush and Unwrap keep streaming responses working through the wrapper.
func (w *sessionWriter) Flush() {
	w.note()
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (w *sessionWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

// makeRoom closes the Owner's oldest sessions when a new one would exceed MaxSessionsPerUser.
// The SDK lists a server's sessions oldest first; the per-request sessions of the stateless
// protocol have no ID and are left alone.
func (s *Server) makeRoom(userID string) {
	s.mu.Lock()
	u := s.users[userID]
	s.mu.Unlock()
	if u == nil {
		return
	}
	var live []*mcp.ServerSession
	for ss := range u.server.Sessions() {
		if ss.ID() != "" {
			live = append(live, ss)
		}
	}
	for i := 0; i <= len(live)-MaxSessionsPerUser; i++ {
		_ = live[i].Close()
	}
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

	// sdkLog is the relay's logger for the MCP SDK: warnings and errors only, so its lines per
	// request and session ("server connecting", "session connected") stay out (FR-635).
	sdkLog *slog.Logger

	// loadTools reads an Owner's current Mac tools (macTools); a field so a test can interleave
	// two syncs.
	loadTools func(ctx context.Context, userID string) []*mcp.Tool
}

// userServer is one Owner's MCP server; its tool list is that Owner's Mac tools.
type userServer struct {
	mu     sync.Mutex
	server *mcp.Server
	tools  map[string]*mcp.Tool // Mac tools currently registered
	grants map[string]string    // session ID → the grant that opened it, where the token named one
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
	if opts.SessionTimeout <= 0 {
		opts.SessionTimeout = DefaultSessionTimeout
	}
	s := &Server{store: st, hub: h, opts: opts, users: map[string]*userServer{}, sdkLog: sdkLogger(opts.Logger)}
	s.loadTools = s.macTools
	sdkLog := s.sdkLog
	// An idle session is closed by the SDK (its next request gets 404 and the client starts a new
	// one, as the MCP transport specifies); without this, sessions lived until restart.
	s.stateful = mcp.NewStreamableHTTPHandler(s.serverFor, &mcp.StreamableHTTPOptions{
		Logger: sdkLog, SessionTimeout: opts.SessionTimeout,
	})
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
	if r.Method == http.MethodPost && r.Header.Get("Mcp-Session-Id") == "" {
		id := userID(r)
		s.makeRoom(id) // this request opens a session
		if grant := grantID(r); grant != "" {
			w = &sessionWriter{ResponseWriter: w, seen: func(session string) { s.noteSession(id, session, grant) }}
		}
	}
	s.stateful.ServeHTTP(w, r)
}

// sdkLogger keeps the SDK's per-request and per-session INFO and DEBUG lines out of the relay
// log, and its warnings and errors in.
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
				&mcp.ServerOptions{Logger: s.sdkLog}),
			tools: map[string]*mcp.Tool{}, grants: map[string]string{},
		}
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
		return nil // validated on arrival, including a trial AddTool; never hand the SDK a tool it would panic on
	}
	return tools
}

// syncTools makes the Owner's server offer exactly the Mac's stored tool list. The lock is taken
// before the list is read: two syncs then apply their lists in the order they read them, so an
// older list can never overwrite a newer one.
func (s *Server) syncTools(ctx context.Context, userID string, u *userServer) {
	u.mu.Lock()
	defer u.mu.Unlock()
	want := map[string]*mcp.Tool{}
	for _, t := range s.loadTools(ctx, userID) {
		want[t.Name] = t
	}
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
		if err := addToolSafely(u.server, t, s.forward(userID, t)); err != nil {
			s.opts.Logger.Error("Mac tool left out", "user", userID, "tool", name, "err", err)
			continue
		}
		u.tools[name] = t
	}
}

// addToolSafely backs up agentproto.ValidateTools: should the SDK still panic on a tool, the
// tool is left out instead of the panic unwinding through the hub or an MCP request.
func addToolSafely(srv *mcp.Server, t *mcp.Tool, h mcp.ToolHandler) error {
	return agentproto.TryAddTool(srv, t, h)
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

func errorResult(text string) *mcp.CallToolResult {
	return &mcp.CallToolResult{IsError: true, Content: []mcp.Content{&mcp.TextContent{Text: text}}}
}

// forward sends a Mac tool call through the hub. The hub bounds it by the tool's deadline.
func (s *Server) forward(userID string, tool *mcp.Tool) mcp.ToolHandler {
	deadline := agentproto.ToolDeadline(tool)
	return func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		start := s.opts.Now()
		callID := agentproto.NewCallID() // made here, so a call that never reaches the Mac has one too (FR-632)
		client := surface(req)           // the same name in the call and in the audit (FR-637)
		st, d := s.status(ctx, userID)
		if !st.Paired {
			s.audit(ctx, userID, "", callID, client, tool.Name, store.OutcomeOffline, start)
			return errorResult(neverPairedText), nil
		}
		res, err := s.hub.CallWithID(ctx, d.ID, callID, client, tool.Name, req.Params.Arguments, deadline, progressFunc(ctx, req))
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
			// The Mac answered: add its state, read after the call so it is current (FR-065).
			now, _ := s.status(ctx, userID)
			appendStatusLine(result, statusLine(now.State))
		}
		s.audit(ctx, userID, d.ID, callID, client, tool.Name, outcome, start)
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

// surface is the Claude app's name from the session's initialize, cleaned (FR-022a); "" when
// the client sent none.
func surface(req *mcp.CallToolRequest) string {
	if info := req.ClientInfo(); info != nil {
		return cleanSurface(info.Name)
	}
	return ""
}

// maxSurfaceRunes caps the audit log's "surface" (FR-022a).
const maxSurfaceRunes = 64

// cleanSurface makes a client's self-chosen name safe to store and show: no control or
// formatting characters (newlines, escapes, direction overrides), at most maxSurfaceRunes.
func cleanSurface(name string) string {
	var b strings.Builder
	n := 0
	for _, r := range name {
		if n == maxSurfaceRunes {
			break
		}
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) || r == utf8.RuneError {
			continue
		}
		b.WriteRune(r)
		n++
	}
	return b.String()
}

// audit records the call, whatever its outcome (FR-022). The write doesn't end with the request:
// a client that went away still leaves its call in the audit.
func (s *Server) audit(ctx context.Context, userID, deviceID, callID, surface, tool, outcome string, start time.Time) {
	err := s.store.AddAudit(context.WithoutCancel(ctx), store.AuditEntry{
		UserID: userID, DeviceID: deviceID, At: start.UTC(), Tool: tool, Surface: surface,
		Outcome: outcome, Duration: s.opts.Now().Sub(start), CallID: callID,
	})
	if err != nil {
		s.opts.Logger.Error("audit", "user", userID, "call", callID, "err", err)
	}
}

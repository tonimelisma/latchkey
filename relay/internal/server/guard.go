package server

import (
	"bufio"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/auth"

	"github.com/tonimelisma/latchkey/relay/internal/events"
	"github.com/tonimelisma/latchkey/relay/internal/limit"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Request body caps. MCP requests carry tool arguments (a file written through Claude, say);
// everything else is a small form or JSON object.
const (
	maxMCPBody   = 16 << 20
	maxOtherBody = 1 << 20
)

// How long a client may take to send a request body (FR-094): the small forms and JSON objects
// of the ordinary routes, and the up to 16 MiB of an MCP request. Variables so tests can shorten
// them.
var (
	otherBodyTimeout = 30 * time.Second
	mcpBodyTimeout   = 2 * time.Minute
)

// deadlineBody clears the connection's read deadline once the body has been read to its end, so
// the deadline covers the body and nothing after it: not a slow tool call's answer, not an MCP
// event stream. (A server-wide ReadTimeout would stay armed during the response and cancel it.)
type deadlineBody struct {
	io.ReadCloser
	rc *http.ResponseController
}

func (b *deadlineBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)
	if err == io.EOF {
		_ = b.rc.SetReadDeadline(time.Time{})
	}
	return n, err
}

// rule is one abuse limit: which requests it covers and its per-key bucket.
type rule struct {
	match func(*http.Request) bool
	per   *limit.Keyed
}

// The limits sit far above what an owner, their Macs, and Claude do in normal use; they only
// slow down guessing, flooding, and table-filling. Claude calls /token and /register from
// Anthropic's shared egress range, so those limits are the loosest.
func defaultRules() []rule {
	post := func(prefixes ...string) func(*http.Request) bool {
		return func(r *http.Request) bool {
			if r.Method != http.MethodPost {
				return false
			}
			for _, p := range prefixes {
				if strings.HasPrefix(r.URL.Path, p) {
					return true
				}
			}
			return false
		}
	}
	path := func(p string) func(*http.Request) bool {
		return func(r *http.Request) bool { return r.URL.Path == p }
	}
	return []rule{
		// Sign-in, passkeys, pairing, account changes: 20 at once, then one every 3 s.
		{post("/auth/", "/passkey/", "/pair", "/account/", "/signout"), limit.NewKeyed(20, 3*time.Second)},
		// Client registration (RFC 7591): 10 at once, then one a minute.
		{post("/register"), limit.NewKeyed(10, time.Minute)},
		// Consent page.
		{path("/authorize"), limit.NewKeyed(60, time.Second)},
		// Token and revocation endpoints: secrets are needed anyway; this only stops floods.
		{post("/token", "/revoke"), limit.NewKeyed(300, 100*time.Millisecond)},
		// Mac connections: a reconnecting Mac retries every few seconds at most.
		{path("/agent/v1"), limit.NewKeyed(30, 2*time.Second)},
	}
}

// guard wraps the relay with security headers, body caps, and per-address abuse limits. Client
// addresses come from X-Forwarded-For only when the peer is loopback or in proxies (FR-082).
func guard(public *url.URL, proxies limit.TrustedProxies, rec *events.Recorder, next http.Handler) http.Handler {
	rules := defaultRules()
	hsts := public != nil && public.Scheme == "https"
	return recordRefusals(rec, next, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		// Pages set their own Content-Security-Policy; everything else loads nothing.
		h.Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
		h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()")
		if !strings.HasPrefix(r.URL.Path, "/static/") {
			h.Set("Cache-Control", "no-store")
		}
		if hsts {
			h.Set("Strict-Transport-Security", "max-age=63072000")
		}

		ip := proxies.ClientIP(r)
		for _, rl := range rules {
			if rl.match(r) && !rl.per.Allow(ip) {
				events.Note(r.Context(), "rate limit per address")
				tooMany(w)
				return
			}
		}

		if r.Body != nil {
			max, timeout := int64(maxOtherBody), otherBodyTimeout
			if r.URL.Path == "/mcp" {
				max, timeout = maxMCPBody, mcpBodyTimeout
			}
			// A request that carries a body must deliver it in time. Requests without one (event
			// streams, the Mac's WebSocket upgrade) get no deadline. Where the connection can't
			// take a deadline, the request goes on without one.
			if r.Body != http.NoBody && r.ContentLength != 0 {
				rc := http.NewResponseController(w)
				if rc.SetReadDeadline(time.Now().Add(timeout)) == nil {
					r.Body = &deadlineBody{ReadCloser: r.Body, rc: rc}
				}
			}
			if r.ContentLength > max {
				events.Note(r.Context(), "request too large")
				http.Error(w, "Request too large.", http.StatusRequestEntityTooLarge)
				return
			}
			r.Body = http.MaxBytesReader(w, r.Body, max)
		}
		next.ServeHTTP(w, r)
	}))
}

// recordRefusals counts every request the relay refused (a 4xx answer) or failed (5xx) in the
// event record, per hour, route, status, and reason (FR-631): the reason is what the handler
// noted (events.Note) or else what the status means; the route is the pattern that matched,
// never the path a client made up. Nothing the client sent, and no address, is recorded.
// routes is the relay's mux, to name the route of a request refused before it was routed.
func recordRefusals(rec *events.Recorder, routes, guarded http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, note := events.WithNote(r.Context())
		r = r.WithContext(ctx)
		sw := &statusWriter{ResponseWriter: w}
		guarded.ServeHTTP(sw, r)
		if sw.status < 400 {
			return
		}
		reason, userID := note()
		if reason == "" {
			reason = statusReason(sw.status)
		}
		route := r.Pattern
		if mux, ok := routes.(*http.ServeMux); ok && route == "" {
			// Refused before routing (a rate limit, a body too large): name the route it was for.
			_, route = mux.Handler(r)
		}
		if route == "" {
			route = "no such page"
		}
		kind := events.RequestRefused
		if sw.status >= 500 {
			kind = events.RequestFailed
		}
		rec.Count(ctx, store.Event{
			Kind: kind, UserID: userID, Detail: route + ": " + strconv.Itoa(sw.status) + " " + reason,
		})
	})
}

func statusReason(status int) string {
	switch {
	case status == http.StatusBadRequest:
		return "malformed or invalid request"
	case status == http.StatusUnauthorized:
		return "not signed in, or the sign-in was rejected"
	case status == http.StatusForbidden:
		return "refused"
	case status == http.StatusNotFound:
		return "not found"
	case status == http.StatusMethodNotAllowed:
		return "method not allowed"
	case status == http.StatusRequestEntityTooLarge:
		return "request too large"
	case status == http.StatusTooManyRequests:
		return "rate limit"
	case status >= 500:
		return "internal error"
	}
	return "refused"
}

// statusWriter notes the response's status. It keeps flushing, hijacking (the Mac's WebSocket),
// and the other optional interfaces working through http.ResponseController.
type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	if w.status == 0 {
		w.status = code
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *statusWriter) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	return w.ResponseWriter.Write(b)
}

func (w *statusWriter) Flush() {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	_ = http.NewResponseController(w.ResponseWriter).Flush()
}

func (w *statusWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if w.status == 0 {
		w.status = http.StatusSwitchingProtocols
	}
	return http.NewResponseController(w.ResponseWriter).Hijack()
}

func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

// perUser limits MCP calls per signed-in owner, after the token is checked: 120 at once, then
// ten a second. A leaked token can't flood the owner's Mac.
func perUser(next http.Handler) http.Handler {
	users := limit.NewKeyed(120, 100*time.Millisecond)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if info := auth.TokenInfoFromContext(r.Context()); info != nil && !users.Allow(info.UserID) {
			events.Note(r.Context(), "rate limit per account")
			tooMany(w)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func tooMany(w http.ResponseWriter) {
	w.Header().Set("Retry-After", "60")
	http.Error(w, "Too many requests. Wait a minute and try again.", http.StatusTooManyRequests)
}

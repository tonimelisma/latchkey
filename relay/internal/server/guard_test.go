package server

import (
	"bytes"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/limit"
)

func TestSecurityHeadersOnEveryResponse(t *testing.T) {
	base, _ := startRelay(t)
	for _, path := range []string{"/healthz", "/.well-known/oauth-authorization-server", "/signin", "/mcp"} {
		res, err := send(t, "GET", base+path, "", nil)
		require.NoError(t, err)
		_ = res.Body.Close()
		h := res.Header
		assert.Equal(t, "nosniff", h.Get("X-Content-Type-Options"), path)
		assert.Equal(t, "DENY", h.Get("X-Frame-Options"), path)
		assert.Equal(t, "no-referrer", h.Get("Referrer-Policy"), path)
		assert.Equal(t, "same-origin", h.Get("Cross-Origin-Opener-Policy"), path)
		assert.Contains(t, h.Get("Content-Security-Policy"), "frame-ancestors 'none'", path)
		assert.Contains(t, h.Get("Permissions-Policy"), "camera=()", path)
		assert.Equal(t, "no-store", h.Get("Cache-Control"), path)
		assert.Empty(t, h.Get("Strict-Transport-Security"), "no HSTS over plain HTTP: "+path)
	}
	res, err := send(t, "GET", base+"/signin", "", nil)
	require.NoError(t, err)
	_ = res.Body.Close()
	assert.Contains(t, res.Header.Get("Content-Security-Policy"), "default-src 'self'", "pages keep their own policy")
	res, err = send(t, "GET", base+"/healthz", "", nil)
	require.NoError(t, err)
	_ = res.Body.Close()
	assert.Contains(t, res.Header.Get("Content-Security-Policy"), "default-src 'none'", "everything else loads nothing")
}

func TestHSTSWhenPublicURLIsHTTPS(t *testing.T) {
	u, _ := url.Parse("https://relay.example.com")
	h := guard(u, nil, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {}))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequestWithContext(t.Context(), "GET", "/healthz", nil))
	assert.Equal(t, "max-age=63072000", w.Header().Get("Strict-Transport-Security"))
}

// FR-082: a private-network peer that isn't a listed proxy can't pick its own rate-limit key by
// sending X-Forwarded-For; a listed one can pass the client's address on.
func TestForwardedForTrustedOnlyFromListedProxies(t *testing.T) {
	burst := func(h http.Handler, peer string) int {
		limited := 0
		for i := range 30 {
			r := httptest.NewRequestWithContext(t.Context(), "POST", "/register", strings.NewReader("{}"))
			r.RemoteAddr = peer
			r.Header.Set("X-Forwarded-For", "198.51.100."+strconv.Itoa(i))
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code == http.StatusTooManyRequests {
				limited++
			}
		}
		return limited
	}
	ok := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {})
	assert.Positive(t, burst(guard(nil, nil, ok), "172.17.0.1:5000"), "unlisted private peer is limited by its own address")
	trusted, err := limit.ParseTrustedProxies("172.17.0.0/16")
	require.NoError(t, err)
	assert.Zero(t, burst(guard(nil, trusted, ok), "172.17.0.1:5000"), "listed proxy: each client has its own bucket")
}

func TestStaticFilesMayBeCached(t *testing.T) {
	base, _ := startRelay(t)
	res, err := send(t, "GET", base+"/static/style.css", "", nil)
	require.NoError(t, err)
	_ = res.Body.Close()
	assert.NotEqual(t, "no-store", res.Header.Get("Cache-Control"))
}

func TestRegistrationIsRateLimitedPerAddress(t *testing.T) {
	base, _ := startRelay(t)
	body := `{"client_name":"x","redirect_uris":["https://claude.ai/api/mcp/auth_callback"]}`
	var last *http.Response
	for range 30 {
		res, err := send(t, "POST", base+"/register", "application/json", strings.NewReader(body))
		require.NoError(t, err)
		_ = res.Body.Close()
		last = res
		if res.StatusCode == http.StatusTooManyRequests {
			break
		}
	}
	require.Equal(t, http.StatusTooManyRequests, last.StatusCode)
	assert.NotEmpty(t, last.Header.Get("Retry-After"))
}

func TestSignInIsRateLimitedPerAddress(t *testing.T) {
	base, _ := startRelay(t)
	var codes []int
	for range 40 {
		res, err := send(t, "POST", base+"/auth/code", "application/json",
			strings.NewReader(`{"email":"a@example.com","code":"000000","purpose":"verify"}`))
		require.NoError(t, err)
		_ = res.Body.Close()
		codes = append(codes, res.StatusCode)
	}
	assert.Contains(t, codes, http.StatusTooManyRequests)
}

func TestOversizedBodiesAreRefused(t *testing.T) {
	base, _ := startRelay(t)
	res, err := send(t, "POST", base+"/token", "application/x-www-form-urlencoded",
		bytes.NewReader(bytes.Repeat([]byte("a"), 2<<20)))
	require.NoError(t, err)
	_ = res.Body.Close()
	assert.Equal(t, http.StatusRequestEntityTooLarge, res.StatusCode)
}

func send(t *testing.T, method, url, contentType string, body io.Reader) (*http.Response, error) {
	t.Helper()
	req, err := http.NewRequestWithContext(t.Context(), method, url, body)
	require.NoError(t, err)
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	return http.DefaultClient.Do(req)
}

// shortBodyTimeouts makes the body deadlines short for a test.
func shortBodyTimeouts(t *testing.T, d time.Duration) {
	t.Helper()
	mcp, other := mcpBodyTimeout, otherBodyTimeout
	mcpBodyTimeout, otherBodyTimeout = d, d
	t.Cleanup(func() { mcpBodyTimeout, otherBodyTimeout = mcp, other })
}

// A client that sends its headers and then trickles (or never sends) the body is cut off after
// the body deadline instead of holding a connection and a goroutine for as long as it likes
// (FR-094).
func TestSlowBodiesAreCutOff(t *testing.T) {
	shortBodyTimeouts(t, 300*time.Millisecond)
	read := make(chan error, 4)
	h := guard(nil, nil, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, err := io.ReadAll(r.Body)
		read <- err
		if err != nil {
			http.Error(w, "body not received", http.StatusBadRequest)
		}
	}))
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)

	for _, path := range []string{"/auth/email", "/mcp"} {
		conn, err := (&net.Dialer{}).DialContext(t.Context(), "tcp", strings.TrimPrefix(srv.URL, "http://"))
		require.NoError(t, err)
		t.Cleanup(func() { _ = conn.Close() }) // before the server closes, which waits for it
		_, err = io.WriteString(conn, "POST "+path+" HTTP/1.1\r\nHost: relay\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{")
		require.NoError(t, err)
		select {
		case err := <-read:
			require.Error(t, err, "the handler's read ends with a timeout: "+path)
		case <-time.After(3 * time.Second):
			t.Fatal("the relay kept waiting for a body that never came: " + path)
		}
		_ = conn.Close()
	}
}

// The deadline covers the body only: once it is read, a slow answer (a tool call, an MCP event
// stream) is not cut off, and the next request on the same connection starts fresh.
func TestBodyDeadlineEndsWithTheBody(t *testing.T) {
	shortBodyTimeouts(t, 200*time.Millisecond)
	h := guard(nil, nil, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, err := io.ReadAll(r.Body); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		select {
		case <-r.Context().Done():
			http.Error(w, "cut off", http.StatusServiceUnavailable)
		case <-time.After(600 * time.Millisecond): // three body deadlines
			_, _ = io.WriteString(w, "done")
		}
	}))
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	for range 2 { // the second reuses the connection
		for _, path := range []string{"/mcp", "/token"} {
			res, err := send(t, "POST", srv.URL+path, "application/json", strings.NewReader(`{"jsonrpc":"2.0"}`))
			require.NoError(t, err)
			body, _ := io.ReadAll(res.Body)
			_ = res.Body.Close()
			assert.Equal(t, http.StatusOK, res.StatusCode, path)
			assert.Equal(t, "done", string(body), path)
		}
	}
	// A request without a body (an event stream, the Mac's WebSocket) gets no deadline at all.
	res, err := send(t, "GET", srv.URL+"/mcp", "", nil)
	require.NoError(t, err)
	body, _ := io.ReadAll(res.Body)
	_ = res.Body.Close()
	assert.Equal(t, "done", string(body))
}

// A suspended Mac tries again every 5 minutes, and at once on wake or a network change
// (FR-204). Even with a network that changes every 10 seconds for a day, its attempts stay far
// below the per-address limit on Mac connections: none is ever refused by it, and the limit is
// still there for a flood.
func TestASuspendedMacRetryingNeverReachesTheConnectionLimit(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/agent/v1", nil)
	var per *limit.Keyed
	for _, r := range defaultRules() {
		if r.match(req) {
			per = r.per
		}
	}
	require.NotNil(t, per, "Mac connections have a limit")

	start := time.Date(2026, 10, 25, 0, 0, 0, 0, time.UTC)
	for at := time.Duration(0); at < 24*time.Hour; at += 10 * time.Second {
		require.True(t, per.AllowAt("203.0.113.7", start.Add(at)), "attempt after %s", at)
	}
	flood := start.Add(48 * time.Hour)
	refused := 0
	for range 100 {
		if !per.AllowAt("203.0.113.7", flood) {
			refused++
		}
	}
	assert.Positive(t, refused, "a flood from the same address is still limited")
}

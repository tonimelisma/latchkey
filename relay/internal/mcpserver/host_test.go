package mcpserver

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/hub"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Regression (the sandbox's first run, 2026-11-26): the MCP SDK refuses, with 403, every request
// that arrives on a loopback address with a non-loopback Host (its DNS rebinding guard), so a
// relay behind a proxy on the same machine (the sandbox's, or a relay run outside Docker behind
// Caddy) refused every MCP call. The relay's own public host is allowed there; any other host
// still isn't, so the rebinding guard stays.
func TestLoopbackRequestsMayNameTheRelaysOwnHost(t *testing.T) {
	st, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "relay.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = st.Close() })
	public, _ := url.Parse("https://relay.latchkey.test:8443")
	s := New(st, hub.New(st, hub.Config{}), Options{PublicURL: public})

	call := func(host string, local net.Addr) *httptest.ResponseRecorder {
		r := httptest.NewRequestWithContext(context.Background(), http.MethodPost, "/mcp", strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`))
		r.Host = host
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Accept", "application/json, text/event-stream")
		r = r.WithContext(context.WithValue(r.Context(), http.LocalAddrContextKey, local))
		w := httptest.NewRecorder()
		s.ServeHTTP(w, r)
		return w
	}
	loop := &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 8444}
	refused := func(w *httptest.ResponseRecorder) bool {
		return w.Code == http.StatusForbidden && strings.Contains(w.Body.String(), "Host")
	}

	assert.False(t, refused(call("relay.latchkey.test:8443", loop)), "the relay's own host, through a proxy on this machine")
	assert.False(t, refused(call("127.0.0.1:8444", loop)), "a loopback host")
	assert.False(t, refused(call("localhost:8444", loop)), "localhost")
	assert.True(t, refused(call("rebind.attacker.example", loop)), "another host on a loopback connection is still refused")
	assert.False(t, refused(call("anything.example", &net.TCPAddr{IP: net.IPv4(172, 17, 0, 2), Port: 8080})), "not a loopback connection")
}

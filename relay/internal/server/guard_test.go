package server

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
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
	h := guard(u, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {}))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequestWithContext(t.Context(), "GET", "/healthz", nil))
	assert.Equal(t, "max-age=63072000", w.Header().Get("Strict-Transport-Security"))
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

package intake_test

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/intake"
	"github.com/tonimelisma/latchkey/relay/reports"
)

const token = "0123456789abcdef0123456789abcdef-developer"

func setup(t *testing.T, perHour int, now time.Time) *httptest.Server {
	t.Helper()
	in, err := intake.Open(filepath.Join(t.TempDir(), "intake.db"), intake.Options{
		DeveloperToken: token, PerHour: perHour, WorkBits: 4, Now: func() time.Time { return now },
	})
	require.NoError(t, err)
	t.Cleanup(func() { _ = in.Close() })
	srv := httptest.NewServer(in.Handler())
	t.Cleanup(srv.Close)
	return srv
}

func sealed(t *testing.T, summary string) ([]byte, string) {
	t.Helper()
	pub, priv, err := reports.GenerateKey()
	require.NoError(t, err)
	pk, err := reports.PublicKey(pub)
	require.NoError(t, err)
	b, err := reports.Seal(pk, reports.Report{Summary: summary, Details: "d"})
	require.NoError(t, err)
	return b, priv
}

func post(t *testing.T, url string, body []byte, hour string, nonce uint64) *http.Response {
	t.Helper()
	req, err := http.NewRequestWithContext(t.Context(), http.MethodPost, url+"/v1/reports", bytes.NewReader(body))
	require.NoError(t, err)
	req.Header.Set("Latchkey-Work-Hour", hour)
	req.Header.Set("Latchkey-Work-Nonce", strconv.FormatUint(nonce, 10))
	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	_ = resp.Body.Close()
	return resp
}

func dev(t *testing.T, method, url, tok string) (*http.Response, []byte) {
	t.Helper()
	req, err := http.NewRequestWithContext(t.Context(), method, url, nil)
	require.NoError(t, err)
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	b, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	return resp, b
}

// Spec 014 FR-1420 to FR-1424: a proven, report-shaped body is taken; the developer lists it,
// gets back exactly the sealed bytes (which open only with the developer's key), and deletes it,
// leaving nothing.
func TestTheDeveloperGetsAndDeletesWhatRelaysSent(t *testing.T) {
	now := time.Date(2026, 11, 23, 5, 45, 0, 0, time.UTC)
	srv := setup(t, 60, now)
	body, priv := sealed(t, "Safari script failed")
	hour := reports.Hour(now)
	resp := post(t, srv.URL, body, hour, reports.Prove(body, hour, 4))
	require.Equal(t, http.StatusAccepted, resp.StatusCode)

	resp, list := dev(t, http.MethodGet, srv.URL+"/v1/reports", token)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	var listed []intake.Listed
	require.NoError(t, json.Unmarshal(list, &listed))
	require.Len(t, listed, 1)

	resp, got := dev(t, http.MethodGet, srv.URL+"/v1/reports/"+listed[0].ID, token)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	assert.Equal(t, body, got)
	k, err := reports.PrivateKey(priv)
	require.NoError(t, err)
	r, err := reports.Open(k, got)
	require.NoError(t, err)
	assert.Equal(t, "Safari script failed", r.Summary)

	resp, _ = dev(t, http.MethodDelete, srv.URL+"/v1/reports/"+listed[0].ID, token)
	assert.Equal(t, http.StatusNoContent, resp.StatusCode)
	_, list = dev(t, http.MethodGet, srv.URL+"/v1/reports", token)
	assert.JSONEq(t, "[]", string(list), "nothing kept")
}

// FR-1420, FR-1423: what isn't a proven sealed report is refused; the developer's endpoints need
// the token.
func TestRefusals(t *testing.T) {
	now := time.Date(2026, 11, 23, 5, 45, 0, 0, time.UTC)
	srv := setup(t, 60, now)
	body, _ := sealed(t, "x")
	hour := reports.Hour(now)
	nonce := reports.Prove(body, hour, 4)

	assert.Equal(t, http.StatusBadRequest, post(t, srv.URL, []byte("hello"), hour, nonce).StatusCode, "not a report")
	assert.Equal(t, http.StatusRequestEntityTooLarge,
		post(t, srv.URL, append([]byte(reports.Magic), make([]byte, reports.MaxSealed)...), hour, 0).StatusCode)
	old := reports.Hour(now.Add(-3 * time.Hour))
	assert.Equal(t, http.StatusForbidden, post(t, srv.URL, body, old, reports.Prove(body, old, 4)).StatusCode, "an old proof")
	wrong := nonce + 1
	for reports.Proven(body, hour, wrong, 4) {
		wrong++
	}
	assert.Equal(t, http.StatusForbidden, post(t, srv.URL, body, hour, wrong).StatusCode, "no proof")

	for _, path := range []string{"/v1/reports", "/v1/reports/rep_x"} {
		resp, _ := dev(t, http.MethodGet, srv.URL+path, "")
		assert.Equal(t, http.StatusUnauthorized, resp.StatusCode, path)
		resp, _ = dev(t, http.MethodGet, srv.URL+path, "wrong-token-wrong-token-wrong-token")
		assert.Equal(t, http.StatusUnauthorized, resp.StatusCode, path)
	}
	resp, _ := dev(t, http.MethodDelete, srv.URL+"/v1/reports/rep_x", "")
	assert.Equal(t, http.StatusUnauthorized, resp.StatusCode)
}

// FR-1421: one sender address gets its hourly number, then waits.
func TestOneSenderIsLimited(t *testing.T) {
	now := time.Date(2026, 11, 23, 5, 45, 0, 0, time.UTC)
	srv := setup(t, 2, now)
	hour := reports.Hour(now)
	for i := 0; i < 2; i++ {
		body, _ := sealed(t, "x")
		require.Equal(t, http.StatusAccepted, post(t, srv.URL, body, hour, reports.Prove(body, hour, 4)).StatusCode)
	}
	body, _ := sealed(t, "x")
	assert.Equal(t, http.StatusTooManyRequests, post(t, srv.URL, body, hour, reports.Prove(body, hour, 4)).StatusCode)
}

func TestATooShortTokenIsRefused(t *testing.T) {
	_, err := intake.Open(filepath.Join(t.TempDir(), "i.db"), intake.Options{DeveloperToken: "short"})
	assert.Error(t, err)
}

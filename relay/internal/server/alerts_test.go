package server

import (
	"crypto/sha256"
	"encoding/base64"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The assembled relay names the client's own address in a security email, as its trusted proxy
// forwarded it (FR-082, FR-699), and sends nothing when an app only refreshes its access.
func TestSecurityEmailNamesTheForwardedAddress(t *testing.T) {
	h := newHarness(t, nil)
	o := h.owner("owner@example.com")
	client := h.registerClient(claudeCallback)
	sum := sha256.Sum256([]byte(strings.Repeat("v", 50)))
	path := "/authorize?" + url.Values{
		"response_type": {"code"}, "client_id": {client}, "redirect_uri": {claudeCallback},
		"scope": {"mcp offline_access"}, "state": {"state-123456789"},
		"code_challenge": {base64.RawURLEncoding.EncodeToString(sum[:])}, "code_challenge_method": {"S256"},
	}.Encode()
	r := h.do(o.http, http.MethodPost, path, "application/x-www-form-urlencoded",
		url.Values{"csrf": {o.csrf(path)}, "decision": {"allow"}}.Encode(),
		map[string]string{"X-Forwarded-For": "203.0.113.7"})
	require.Equal(t, http.StatusSeeOther, r.status, r.body)

	require.Eventually(t, func() bool { return len(h.mail.Sent()) == 1 }, 5*time.Second, 10*time.Millisecond)
	m := h.mail.Sent()[0]
	assert.Equal(t, "owner@example.com", m.To)
	assert.Equal(t, "An app was allowed to use your Latchkey machines", m.Subject)
	assert.Contains(t, m.Body, "The request came from the IP address 203.0.113.7.")
	assert.Contains(t, m.Body, h.base+"/account")

	// Connecting another app the usual way, then refreshing its access: one more email, for
	// the approval only.
	_, refresh := o.approve(client, claudeCallback)
	tok := h.do(nil, http.MethodPost, "/token", "application/x-www-form-urlencoded",
		url.Values{"grant_type": {"refresh_token"}, "refresh_token": {refresh}, "client_id": {client}}.Encode(), nil)
	require.Equal(t, http.StatusOK, tok.status, tok.body)
	require.Eventually(t, func() bool { return len(h.mail.Sent()) == 2 }, 5*time.Second, 10*time.Millisecond)
	time.Sleep(200 * time.Millisecond) // anything the refresh would have sent
	assert.Len(t, h.mail.Sent(), 2)
}

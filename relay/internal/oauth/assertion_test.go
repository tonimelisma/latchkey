package oauth_test

import (
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// A client assertion (private_key_jwt, client_secret_jwt) is refused without being parsed: a
// huge one that a JWT parser would spend seconds on (GHSA-mgcc-cww5-fp2q) is answered at once,
// at /token and /revoke, for every grant type, with or without a known client.
func TestClientAssertionRefusedUnparsed(t *testing.T) {
	e := setup(t)
	id := e.register("https://claude.ai/api/mcp/auth_callback")
	_, refresh := e.tokens(id)
	// A compact JWS header and a payload of a million dots: many parts, the shape that made
	// go-jose v3 slow.
	huge := "eyJhbGciOiJSUzI1NiJ9." + strings.Repeat(".", 1<<20) + "x"
	for _, form := range []url.Values{
		{"grant_type": {"refresh_token"}, "refresh_token": {refresh}, "client_id": {id}},
		{"grant_type": {"authorization_code"}, "code": {"x"}, "redirect_uri": {"https://claude.ai/api/mcp/auth_callback"}, "code_verifier": {"x"}},
		{"grant_type": {"refresh_token"}, "refresh_token": {refresh}},
	} {
		for _, typ := range []string{"urn:ietf:params:oauth:client-assertion-type:jwt-bearer", ""} {
			f := url.Values{}
			for k, v := range form {
				f[k] = v
			}
			f.Set("client_assertion", huge)
			if typ != "" {
				f.Set("client_assertion_type", typ)
			}
			start := time.Now()
			resp, m := e.tokenRequest(f)
			assert.Less(t, time.Since(start), time.Second, "refused without parsing")
			assert.Equal(t, http.StatusUnauthorized, resp.StatusCode, m)
			assert.Equal(t, "invalid_client", m["error"])
			assert.NotContains(t, m, "access_token")
		}
	}
	start := time.Now()
	r := e.do(http.MethodPost, "/revoke", strings.NewReader(url.Values{
		"token": {refresh}, "client_assertion": {huge},
		"client_assertion_type": {"urn:ietf:params:oauth:client-assertion-type:jwt-bearer"},
	}.Encode()), "application/x-www-form-urlencoded", false)
	assert.Less(t, time.Since(start), time.Second)
	assert.Equal(t, http.StatusUnauthorized, r.StatusCode)

	// The refresh token was neither used nor revoked by any of it.
	resp, m := e.tokenRequest(url.Values{"grant_type": {"refresh_token"}, "refresh_token": {refresh}, "client_id": {id}})
	require.Equal(t, http.StatusOK, resp.StatusCode, m)
}

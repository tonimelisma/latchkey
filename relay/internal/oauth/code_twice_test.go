package oauth_test

import (
	"net/http"
	"net/url"
	"testing"

	"github.com/ory/fosite"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The one order in which a code presented twice at once used to leave the first exchange's
// access standing (FR-096): the second exchange reads the code while it is still unused, the
// first exchange then runs to its end, and the second goes on to the PKCE check. fosite deletes
// the PKCE challenge on first use, so the second exchange found none and stopped there, before
// the step that notices the double use. The second exchange's storage calls are made here in
// fosite's order (HandleTokenEndpointRequest of handler/oauth2 and handler/pkce, then
// PopulateTokenEndpointResponse), around a real first exchange.
func TestCodePresentedTwiceEndsTheGrantWhenTheSecondReadItFirst(t *testing.T) {
	e := setup(t)
	ctx := ctxT(t)
	const redirect = "https://claude.ai/api/mcp/auth_callback"
	id := e.register(redirect)
	p := newPKCE()
	code := e.approve(authorizeURL(id, redirect, &p, nil)).Query().Get("code")
	require.NotEmpty(t, code)

	require.NoError(t, e.oauth.ReadCode(ctx, code), "the second exchange reads the code: unused")

	resp, m := e.tokenRequest(url.Values{
		"grant_type": {"authorization_code"}, "code": {code}, "redirect_uri": {redirect},
		"client_id": {id}, "code_verifier": {p.verifier},
	})
	require.Equal(t, http.StatusOK, resp.StatusCode, m)
	access, _ := m["access_token"].(string)
	require.Equal(t, http.StatusOK, e.mcpStatus(access), "the first exchange got access")

	require.NoError(t, e.oauth.ReadPKCE(ctx, code), "the second exchange still gets past the PKCE check")
	require.ErrorIs(t, e.oauth.ReadCode(ctx, code), fosite.ErrInvalidatedAuthorizeCode, "and is then told the code was used")
	assert.Equal(t, http.StatusUnauthorized, e.mcpStatus(access), "which ends the access the first exchange got")
}

package oauth_test

import (
	"net/http"
	"net/url"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/zitadel/oidc/v3/pkg/oidc"
)

// The order in which a code presented twice at once could leave the first exchange's access
// standing (FR-096): the second exchange reads the code while it is still unused, the first
// exchange then runs to its end, and the second goes on to issue tokens. The second exchange's
// storage calls are made here in zitadel's order (AuthRequestByCode in AuthorizeCodeClient,
// then CreateAccessAndRefreshTokens in CreateAccessToken), around a real first exchange.
func TestCodePresentedTwiceEndsTheGrantWhenTheSecondReadItFirst(t *testing.T) {
	e := setup(t)
	ctx := ctxT(t)
	const redirect = "https://claude.ai/api/mcp/auth_callback"
	id := e.register(redirect)
	p := newPKCE()
	code := e.approve(authorizeURL(id, redirect, &p, nil)).Query().Get("code")
	require.NotEmpty(t, code)

	second, err := e.oauth.ReadCode(ctx, code)
	require.NoError(t, err, "the second exchange reads the code: unused")

	resp, m := e.tokenRequest(url.Values{
		"grant_type": {"authorization_code"}, "code": {code}, "redirect_uri": {redirect},
		"client_id": {id}, "code_verifier": {p.verifier},
	})
	require.Equal(t, http.StatusOK, resp.StatusCode, m)
	access, _ := m["access_token"].(string)
	require.Equal(t, http.StatusOK, e.mcpStatus(access), "the first exchange got access")

	err = e.oauth.IssueFor(ctx, second)
	require.ErrorIs(t, err, oidc.ErrInvalidGrant(), "the second is told the code was used")
	assert.Equal(t, http.StatusUnauthorized, e.mcpStatus(access), "which ends the access the first exchange got")

	_, err = e.oauth.ReadCode(ctx, code)
	require.ErrorIs(t, err, oidc.ErrInvalidGrant(), "and the code stays used")
}

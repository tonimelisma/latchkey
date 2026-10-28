package oauth

import (
	"context"
	"crypto/sha256"
	"net/url"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/zitadel/oidc/v3/pkg/oidc"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// A code is never exchanged without its PKCE challenge (security review of the move to
// zitadel/oidc): a code row from before the move keeps its challenge in its own form or in the
// pkce row fosite wrote beside it; a code with neither is refused, never exchanged without PKCE.
func TestCodeWithoutChallengeIsRefused(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(ctx, filepath.Join(t.TempDir(), "relay.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = st.Close() })
	u, err := st.CreateUser(ctx, "owner@example.com", time.Now())
	require.NoError(t, err)
	const redirect = "https://claude.ai/api/mcp/auth_callback"
	require.NoError(t, st.PutOAuthClient(ctx, store.OAuthClient{
		ID: "cl_1", Kind: "dcr", CreatedAt: time.Now(),
		MetadataJSON: []byte(`{"redirect_uris":["` + redirect + `"],"token_endpoint_auth_method":"none"}`),
	}))
	cl := &clients{st: st, now: time.Now, failed: map[[sha256.Size]byte]time.Time{}, allowed: AnyClientHost()}
	s := &storage{st: st, clients: cl, now: time.Now, tokens: newHMACTokens([]byte("0123456789abcdef0123456789abcdef"))}

	code, sig := s.tokens.generate(prefixCode)
	row := store.OAuthRequest{
		Signature: sig, Kind: store.KindCode, RequestID: "req1", ClientID: "cl_1", UserID: u.ID,
		RequestedAt: time.Now(), Scopes: "mcp", GrantedScopes: "mcp",
		Form:        url.Values{"redirect_uri": {redirect}, "state": {"state-123456789"}}.Encode(),
		SessionJSON: []byte(`{}`), ExpiresAt: time.Now().Add(time.Minute),
	}
	require.NoError(t, st.PutOAuthRequest(ctx, row))
	_, err = s.AuthRequestByCode(ctx, code)
	require.ErrorIs(t, err, oidc.ErrInvalidGrant(), "no challenge anywhere: refused")

	pkce := row
	pkce.Kind = store.KindPKCE
	pkce.Form = url.Values{"redirect_uri": {redirect}, "code_challenge": {"abc"}, "code_challenge_method": {"S256"}}.Encode()
	require.NoError(t, st.PutOAuthRequest(ctx, pkce))
	req, err := s.AuthRequestByCode(ctx, code)
	require.NoError(t, err, "the challenge from fosite's pkce row")
	require.NotNil(t, req.GetCodeChallenge())
	assert.Equal(t, "abc", req.GetCodeChallenge().Challenge)
	assert.Equal(t, oidc.CodeChallengeMethodS256, req.GetCodeChallenge().Method)
}

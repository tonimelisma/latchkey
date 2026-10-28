package oauth

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/zitadel/oidc/v3/pkg/oidc"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Using a code is one step that only one exchange can take: the second one is told the code is
// used (whatever it read before), and the grant's rows are marked revoked so that neither
// exchange's tokens work, as for a replay (FR-096).
func TestUsingACodeHappensOnce(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(ctx, filepath.Join(t.TempDir(), "relay.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = st.Close() })
	u, err := st.CreateUser(ctx, "owner@example.com", time.Now())
	require.NoError(t, err)
	s := &storage{st: st, now: time.Now}
	row := store.OAuthRequest{
		Signature: "code-sig", Kind: store.KindCode, RequestID: "req1", ClientID: "cl_1", UserID: u.ID,
		RequestedAt: time.Now(), SessionJSON: []byte(`{}`), ExpiresAt: time.Now().Add(time.Minute),
	}
	require.NoError(t, st.PutOAuthRequest(ctx, row))

	require.NoError(t, s.useCode(ctx, row), "the first exchange")
	access := row
	access.Signature, access.Kind = "access-sig", store.KindAccess
	require.NoError(t, st.PutOAuthToken(ctx, access), "which gets its token")

	require.ErrorIs(t, s.useCode(ctx, row), oidc.ErrInvalidGrant(),
		"a second exchange that read the code before it was marked used")
	got, err := st.OAuthRequest(ctx, store.KindAccess, "access-sig")
	require.NoError(t, err)
	assert.False(t, got.RevokedAt.IsZero(), "the first exchange's token is revoked")
	refresh := row
	refresh.Signature, refresh.Kind = "refresh-sig", store.KindRefresh
	require.ErrorIs(t, st.PutOAuthToken(ctx, refresh), store.ErrNotFound, "and no further token is written for the grant")

	gone := row
	gone.Signature = "no-such-code"
	require.ErrorIs(t, s.useCode(ctx, gone), oidc.ErrInvalidGrant())
}

// The token format is the one the relay has always issued (fosite's prefixed HMAC-SHA512/256),
// so tokens from before the move to zitadel/oidc are read: this pins a token made by fosite
// 0.49 under a known secret (FR-188).
func TestTokenFormatReadsEarlierTokens(t *testing.T) {
	secret := []byte("0123456789abcdef0123456789abcdef")
	tok := newHMACTokens(secret)
	// Checked against fosite 0.49's HMACSHAStrategy (GlobalSecret = secret, key bytes 0 to 31) before fosite was removed.
	const fositeToken = "ory_rt_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8.3RoVBAJ3lVhnYh077jrkVPJQjp987MkRaieXBMg9npQ"
	sig, ok := tok.signature(prefixRefresh, fositeToken)
	require.True(t, ok)
	assert.Equal(t, "3RoVBAJ3lVhnYh077jrkVPJQjp987MkRaieXBMg9npQ", sig)

	_, ok = tok.signature(prefixAccess, fositeToken)
	assert.False(t, ok, "a refresh token is not an access token")
	_, ok = tok.signature(prefixRefresh, fositeToken+"x")
	assert.False(t, ok, "an altered token is refused")
	_, ok = newHMACTokens([]byte("another secret, 32 bytes long!!!")).signature(prefixRefresh, fositeToken)
	assert.False(t, ok, "under another secret")

	fresh, freshSig := tok.generate(prefixAccess)
	got, ok := tok.signature(prefixAccess, fresh)
	require.True(t, ok)
	assert.Equal(t, freshSig, got)
}

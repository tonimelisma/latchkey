package oauth

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/ory/fosite"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Using a code is one step that only one exchange can take: the second one is told the code is
// used (whatever it read before), and the grant's rows are marked revoked so that neither
// exchange's tokens work, as for a replay (FR-096).
func TestInvalidatingACodeHappensOnce(t *testing.T) {
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

	require.NoError(t, s.InvalidateAuthorizeCodeSession(ctx, "code-sig"), "the first exchange")
	access := row
	access.Signature, access.Kind = "access-sig", store.KindAccess
	require.NoError(t, st.PutOAuthToken(ctx, access), "which gets its token")

	require.ErrorIs(t, s.InvalidateAuthorizeCodeSession(ctx, "code-sig"), fosite.ErrInvalidatedAuthorizeCode,
		"a second exchange that read the code before it was marked used")
	got, err := st.OAuthRequest(ctx, store.KindAccess, "access-sig")
	require.NoError(t, err)
	assert.False(t, got.RevokedAt.IsZero(), "the first exchange's token is revoked")
	refresh := row
	refresh.Signature, refresh.Kind = "refresh-sig", store.KindRefresh
	require.ErrorIs(t, st.PutOAuthToken(ctx, refresh), store.ErrNotFound, "and no further token is written for the grant")

	require.ErrorIs(t, s.InvalidateAuthorizeCodeSession(ctx, "no-such-code"), fosite.ErrInvalidatedAuthorizeCode)
}

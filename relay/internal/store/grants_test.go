package store_test

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

func putToken(t *testing.T, s *store.Store, sig, kind, requestID, userID string, at time.Time, life time.Duration) {
	t.Helper()
	require.NoError(t, s.PutOAuthRequest(context.Background(), store.OAuthRequest{
		Signature: sig, Kind: kind, RequestID: requestID, ClientID: "cl_shared", UserID: userID,
		RequestedAt: at, SessionJSON: []byte(`{}`), ExpiresAt: at.Add(life),
	}))
}

func addGrant(t *testing.T, s *store.Store, requestID, userID, name string, at time.Time) store.Grant {
	t.Helper()
	g := store.Grant{
		RequestID: requestID, ID: store.NewGrantID(), UserID: userID, ClientID: "cl_shared",
		ClientName: name, ClientHost: "claude.ai", Redirect: "claude.ai", ApprovedAt: at,
	}
	require.NoError(t, s.AddGrant(context.Background(), g))
	return g
}

// The apps with access are the approvals that still hold a live token, newest first; two
// approvals of one client are two entries (FR-190).
func TestLiveGrants(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	old := addGrant(t, s, "req-old", u.ID, "Claude", t0)
	putToken(t, s, "a1", store.KindAccess, "req-old", u.ID, t0, time.Hour)
	putToken(t, s, "r1", store.KindRefresh, "req-old", u.ID, t0, 24*time.Hour)
	newer := addGrant(t, s, "req-new", u.ID, "Claude", t0.Add(time.Hour))
	putToken(t, s, "r2", store.KindRefresh, "req-new", u.ID, t0.Add(time.Hour), 24*time.Hour)
	addGrant(t, s, "req-code", u.ID, "Never redeemed", t0)
	putToken(t, s, "c1", store.KindCode, "req-code", u.ID, t0, time.Hour)
	addGrant(t, s, "req-expired", u.ID, "Expired", t0)
	putToken(t, s, "a2", store.KindAccess, "req-expired", u.ID, t0, time.Minute)
	addGrant(t, s, "req-revoked", u.ID, "Revoked", t0)
	putToken(t, s, "r3", store.KindRefresh, "req-revoked", u.ID, t0, 24*time.Hour)
	require.NoError(t, s.RevokeGrant(ctx, "req-revoked", t0))

	now := t0.Add(2 * time.Hour)
	got, err := s.LiveGrants(ctx, u.ID, now, 50)
	require.NoError(t, err)
	require.Len(t, got, 2)
	assert.Equal(t, []string{newer.ID, old.ID}, []string{got[0].ID, got[1].ID}, "newest approval first")
	assert.Equal(t, "Claude", got[0].ClientName)
	assert.Equal(t, t0.Add(time.Hour), got[0].ApprovedAt)
	assert.True(t, got[0].LastUsedAt.IsZero())
	assert.NotEqual(t, got[0].ID, got[1].ID)

	one, err := s.LiveGrants(ctx, u.ID, now, 1)
	require.NoError(t, err)
	assert.Len(t, one, 1, "the list is capped")

	live, err := s.GrantLive(ctx, "req-old", now)
	require.NoError(t, err)
	assert.True(t, live)
	live, err = s.GrantLive(ctx, "req-revoked", now)
	require.NoError(t, err)
	assert.False(t, live)

	g, err := s.GrantByRequest(ctx, "req-new")
	require.NoError(t, err)
	assert.Equal(t, newer.ID, g.ID)
	assert.Equal(t, u.ID, g.UserID)
}

// Removing one grant deletes its codes and tokens and nothing else; the ID of another
// account's grant, or an unknown one, changes nothing (FR-191).
func TestDeleteGrantRemovesExactlyOne(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	other, err := s.CreateUser(ctx, "other@example.com", t0)
	require.NoError(t, err)
	a := addGrant(t, s, "req-a", u.ID, "Claude", t0)
	putToken(t, s, "a-access", store.KindAccess, "req-a", u.ID, t0, time.Hour)
	putToken(t, s, "a-refresh", store.KindRefresh, "req-a", u.ID, t0, time.Hour)
	b := addGrant(t, s, "req-b", u.ID, "Claude", t0)
	putToken(t, s, "b-refresh", store.KindRefresh, "req-b", u.ID, t0, time.Hour)
	theirs := addGrant(t, s, "req-c", other.ID, "Claude", t0)
	putToken(t, s, "c-refresh", store.KindRefresh, "req-c", other.ID, t0, time.Hour)

	removed, err := s.DeleteGrant(ctx, u.ID, theirs.ID)
	require.NoError(t, err)
	assert.False(t, removed, "another account's grant")
	removed, err = s.DeleteGrant(ctx, u.ID, "grt_unknown")
	require.NoError(t, err)
	assert.False(t, removed)
	_, err = s.OAuthRequest(ctx, store.KindRefresh, "c-refresh")
	require.NoError(t, err, "the other account's token is untouched")

	removed, err = s.DeleteGrant(ctx, u.ID, a.ID)
	require.NoError(t, err)
	assert.True(t, removed)
	for _, sig := range []string{"a-access", "a-refresh"} {
		kind := store.KindAccess
		if sig == "a-refresh" {
			kind = store.KindRefresh
		}
		_, err = s.OAuthRequest(ctx, kind, sig)
		require.ErrorIs(t, err, store.ErrNotFound, sig)
	}
	_, err = s.OAuthRequest(ctx, store.KindRefresh, "b-refresh")
	require.NoError(t, err, "the other grant keeps working")
	got, err := s.LiveGrants(ctx, u.ID, t0, 50)
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, b.ID, got[0].ID)

	// No token can be written for the removed grant afterwards.
	err = s.PutOAuthToken(ctx, store.OAuthRequest{
		Signature: "late", Kind: store.KindAccess, RequestID: "req-a", ClientID: "cl_shared", UserID: u.ID,
		RequestedAt: t0, SessionJSON: []byte(`{}`), ExpiresAt: t0.Add(time.Hour),
	})
	require.ErrorIs(t, err, store.ErrNotFound)
}

func TestTouchGrantAndCleanup(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	g := addGrant(t, s, "req-a", u.ID, "Claude", t0)
	putToken(t, s, "a-refresh", store.KindRefresh, "req-a", u.ID, t0, time.Hour)
	require.NoError(t, s.TouchGrant(ctx, "req-a", t0.Add(time.Minute)))
	got, err := s.LiveGrants(ctx, u.ID, t0, 50)
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, t0.Add(time.Minute), got[0].LastUsedAt)

	// "Remove Claude's access" removes the grants with the tokens.
	require.NoError(t, s.DeleteUserOAuth(ctx, u.ID))
	_, err = s.GrantByRequest(ctx, "req-a")
	require.ErrorIs(t, err, store.ErrNotFound)

	// The purge drops a grant once none of its codes or tokens is left.
	addGrant(t, s, "req-b", u.ID, "Claude", t0)
	putToken(t, s, "b-access", store.KindAccess, "req-b", u.ID, t0, time.Minute)
	require.NoError(t, s.PurgeExpired(ctx, t0.Add(time.Hour)))
	_, err = s.GrantByRequest(ctx, "req-b")
	require.ErrorIs(t, err, store.ErrNotFound)

	assert.Regexp(t, `^[A-Za-z0-9_-]{1,64}$`, g.ID)
	assert.NotContains(t, g.ID, "req-a")
}

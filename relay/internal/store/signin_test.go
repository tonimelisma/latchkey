package store_test

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

func TestUserLookupVerifyDelete(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	got, err := s.UserByEmail(ctx, "a@example.com")
	require.NoError(t, err)
	assert.Equal(t, u.ID, got.ID)

	require.NoError(t, s.VerifyEmail(ctx, u.ID, t0))
	got, err = s.User(ctx, u.ID)
	require.NoError(t, err)
	assert.Equal(t, t0, got.EmailVerifiedAt)

	d := newDevice(t, s, u.ID)
	require.NoError(t, s.AddAudit(ctx, store.AuditEntry{UserID: u.ID, DeviceID: d.ID, At: t0, Tool: "x", Outcome: store.OutcomeOK}))
	require.NoError(t, s.CreateSession(ctx, []byte("sess"), u.ID, t0, t0.Add(time.Hour)))

	require.NoError(t, s.DeleteUser(ctx, u.ID))
	_, err = s.User(ctx, u.ID)
	require.ErrorIs(t, err, store.ErrNotFound)
	_, err = s.Device(ctx, d.ID)
	require.ErrorIs(t, err, store.ErrNotFound, "devices are deleted with the account")
	entries, err := s.AuditForUser(ctx, u.ID, 10)
	require.NoError(t, err)
	assert.Empty(t, entries)
	_, err = s.Session(ctx, []byte("sess"), t0)
	require.ErrorIs(t, err, store.ErrNotFound)
}

func TestPurgeUnverifiedUsers(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	stale := newUser(t, s)
	fresh, err := s.CreateUser(ctx, "b@example.com", t0.Add(2*time.Hour))
	require.NoError(t, err)
	verified, err := s.CreateUser(ctx, "c@example.com", t0)
	require.NoError(t, err)
	require.NoError(t, s.VerifyEmail(ctx, verified.ID, t0))

	n, err := s.PurgeUnverifiedUsers(ctx, t0.Add(time.Hour))
	require.NoError(t, err)
	assert.Equal(t, int64(1), n)
	_, err = s.User(ctx, stale.ID)
	require.ErrorIs(t, err, store.ErrNotFound)
	_, err = s.User(ctx, fresh.ID)
	require.NoError(t, err)
	_, err = s.User(ctx, verified.ID)
	require.NoError(t, err)
}

func TestPasskeys(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	require.NoError(t, s.AddPasskey(ctx, u.ID, []byte("cred1"), []byte(`{"n":1}`), t0))
	require.NoError(t, s.AddPasskey(ctx, u.ID, []byte("cred2"), []byte(`{"n":2}`), t0))
	require.ErrorIs(t, s.AddPasskey(ctx, u.ID, []byte("cred1"), []byte(`{}`), t0), store.ErrConflict)

	keys, err := s.Passkeys(ctx, u.ID)
	require.NoError(t, err)
	require.Len(t, keys, 2)

	pk, err := s.PasskeyByCredentialID(ctx, []byte("cred2"))
	require.NoError(t, err)
	assert.Equal(t, u.ID, pk.UserID)
	assert.JSONEq(t, `{"n":2}`, string(pk.CredentialJSON))

	require.NoError(t, s.UpdatePasskey(ctx, []byte("cred2"), []byte(`{"n":3}`), t0.Add(time.Minute)))
	pk, err = s.PasskeyByCredentialID(ctx, []byte("cred2"))
	require.NoError(t, err)
	assert.JSONEq(t, `{"n":3}`, string(pk.CredentialJSON))
	assert.Equal(t, t0.Add(time.Minute), pk.LastUsedAt)

	n, err := s.DeletePasskeysExcept(ctx, u.ID, []byte("cred2"))
	require.NoError(t, err)
	assert.Equal(t, int64(1), n)
	keys, err = s.Passkeys(ctx, u.ID)
	require.NoError(t, err)
	require.Len(t, keys, 1)
	assert.Equal(t, []byte("cred2"), keys[0].CredentialID)
}

func TestEmailTokens(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	require.NoError(t, s.CreateEmailToken(ctx, []byte("h"), u.ID, store.PurposeRecover, t0.Add(15*time.Minute)))

	_, err := s.PeekEmailToken(ctx, []byte("h"), store.PurposeVerify, t0)
	require.ErrorIs(t, err, store.ErrNotFound, "purpose must match")
	id, err := s.PeekEmailToken(ctx, []byte("h"), store.PurposeRecover, t0)
	require.NoError(t, err)
	assert.Equal(t, u.ID, id)
	_, err = s.PeekEmailToken(ctx, []byte("h"), store.PurposeRecover, t0.Add(16*time.Minute))
	require.ErrorIs(t, err, store.ErrNotFound, "expired")

	id, err = s.UseEmailToken(ctx, []byte("h"), store.PurposeRecover, t0)
	require.NoError(t, err)
	assert.Equal(t, u.ID, id)
	_, err = s.UseEmailToken(ctx, []byte("h"), store.PurposeRecover, t0)
	require.ErrorIs(t, err, store.ErrNotFound, "single use")
	_, err = s.PeekEmailToken(ctx, []byte("h"), store.PurposeRecover, t0)
	require.ErrorIs(t, err, store.ErrNotFound)

	used, err := s.RecoveriesSince(ctx, u.ID, t0.Add(-time.Minute))
	require.NoError(t, err)
	assert.Equal(t, []time.Time{t0}, used)
}

func TestSessions(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	require.NoError(t, s.CreateSession(ctx, []byte("a"), u.ID, t0, t0.Add(time.Hour)))
	sess, err := s.Session(ctx, []byte("a"), t0)
	require.NoError(t, err)
	assert.Equal(t, u.ID, sess.UserID)
	assert.True(t, sess.ReauthAt.IsZero())

	require.NoError(t, s.SetSessionReauth(ctx, []byte("a"), t0.Add(time.Minute)))
	sess, err = s.Session(ctx, []byte("a"), t0)
	require.NoError(t, err)
	assert.Equal(t, t0.Add(time.Minute), sess.ReauthAt)

	_, err = s.Session(ctx, []byte("a"), t0.Add(2*time.Hour))
	require.ErrorIs(t, err, store.ErrNotFound, "expired")
	require.NoError(t, s.DeleteSession(ctx, []byte("a")))
	_, err = s.Session(ctx, []byte("a"), t0)
	require.ErrorIs(t, err, store.ErrNotFound)

	require.NoError(t, s.CreateSession(ctx, []byte("b"), u.ID, t0, t0.Add(time.Hour)))
	require.NoError(t, s.DeleteUserSessions(ctx, u.ID))
	_, err = s.Session(ctx, []byte("b"), t0)
	require.ErrorIs(t, err, store.ErrNotFound)
}

func TestPairingCodes(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	require.NoError(t, s.CreatePairingCode(ctx, []byte("c"), u.ID, t0.Add(5*time.Minute)))
	_, err := s.UsePairingCode(ctx, []byte("c"), t0.Add(6*time.Minute))
	require.ErrorIs(t, err, store.ErrNotFound, "expired")
	id, err := s.UsePairingCode(ctx, []byte("c"), t0)
	require.NoError(t, err)
	assert.Equal(t, u.ID, id)
	_, err = s.UsePairingCode(ctx, []byte("c"), t0)
	require.ErrorIs(t, err, store.ErrNotFound, "single use")
}

func TestOAuthClients(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	c := store.OAuthClient{ID: "cl_1", Kind: "dcr", MetadataJSON: []byte(`{"client_name":"Claude"}`), CreatedAt: t0}
	require.NoError(t, s.PutOAuthClient(ctx, c))
	got, err := s.OAuthClient(ctx, "cl_1")
	require.NoError(t, err)
	assert.Equal(t, c, got)

	c.MetadataJSON = []byte(`{"client_name":"Claude 2"}`)
	c.FetchedAt = t0.Add(time.Hour)
	require.NoError(t, s.PutOAuthClient(ctx, c))
	got, err = s.OAuthClient(ctx, "cl_1")
	require.NoError(t, err)
	assert.Equal(t, c, got)
	_, err = s.OAuthClient(ctx, "missing")
	require.ErrorIs(t, err, store.ErrNotFound)
}

func TestOAuthRequests(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	r := store.OAuthRequest{
		Signature: "sig1", Kind: store.KindRefresh, RequestID: "req1", ClientID: "cl_1", UserID: u.ID,
		RequestedAt: t0, Scopes: "mcp offline_access", GrantedScopes: "mcp offline_access",
		Form: "a=b", SessionJSON: []byte(`{}`), ExpiresAt: t0.Add(time.Hour),
	}
	require.NoError(t, s.PutOAuthRequest(ctx, r))
	got, err := s.OAuthRequest(ctx, store.KindRefresh, "sig1")
	require.NoError(t, err)
	assert.Equal(t, r, got)
	_, err = s.OAuthRequest(ctx, store.KindAccess, "sig1")
	require.ErrorIs(t, err, store.ErrNotFound)

	require.NoError(t, s.RotateOAuthRequest(ctx, store.KindRefresh, "sig1", t0.Add(time.Minute)))
	require.NoError(t, s.RotateOAuthRequest(ctx, store.KindRefresh, "sig1", t0.Add(2*time.Minute)))
	got, err = s.OAuthRequest(ctx, store.KindRefresh, "sig1")
	require.NoError(t, err)
	assert.Equal(t, t0.Add(time.Minute), got.RotatedAt, "first rotation wins")

	require.NoError(t, s.MarkOAuthRequestUsed(ctx, store.KindRefresh, "sig1", t0))
	got, err = s.OAuthRequest(ctx, store.KindRefresh, "sig1")
	require.NoError(t, err)
	assert.Equal(t, t0, got.UsedAt)

	a := r
	a.Signature, a.Kind = "sig2", store.KindAccess
	require.NoError(t, s.PutOAuthRequest(ctx, a))
	require.NoError(t, s.RevokeOAuthRequests(ctx, store.KindAccess, "req1", t0))
	got, err = s.OAuthRequest(ctx, store.KindAccess, "sig2")
	require.NoError(t, err)
	assert.Equal(t, t0, got.RevokedAt)

	require.NoError(t, s.DeleteOAuthRequest(ctx, store.KindAccess, "sig2"))
	_, err = s.OAuthRequest(ctx, store.KindAccess, "sig2")
	require.ErrorIs(t, err, store.ErrNotFound)

	// Revoking Claude's access deletes every token (FR-044).
	require.NoError(t, s.DeleteUserOAuth(ctx, u.ID))
	_, err = s.OAuthRequest(ctx, store.KindRefresh, "sig1")
	require.ErrorIs(t, err, store.ErrNotFound)
}

// The account page's list of Claude clients is whoever holds a live token (FR-049a: no approval
// is remembered beyond the tokens it produced).
func TestClientsWithAccess(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	put := func(sig, kind, client string, at time.Time, life time.Duration) {
		require.NoError(t, s.PutOAuthRequest(ctx, store.OAuthRequest{
			Signature: sig, Kind: kind, RequestID: "req-" + sig, ClientID: client, UserID: u.ID,
			RequestedAt: at, SessionJSON: []byte(`{}`), ExpiresAt: at.Add(life),
		}))
	}
	put("a1", store.KindAccess, "cl_old", t0, time.Hour)
	put("r1", store.KindRefresh, "cl_old", t0.Add(time.Minute), 24*time.Hour)
	put("r2", store.KindRefresh, "cl_new", t0.Add(time.Hour), 24*time.Hour)
	put("c1", store.KindCode, "cl_code_only", t0, time.Hour)
	put("a2", store.KindAccess, "cl_expired", t0, time.Minute)
	put("a3", store.KindAccess, "cl_revoked", t0, time.Hour)
	require.NoError(t, s.RevokeOAuthRequests(ctx, store.KindAccess, "req-a3", t0))

	got, err := s.ClientsWithAccess(ctx, u.ID, t0.Add(30*time.Minute))
	require.NoError(t, err)
	assert.Equal(t, []store.ClientAccess{{ClientID: "cl_new", Since: t0.Add(time.Hour)}, {ClientID: "cl_old", Since: t0}}, got)

	require.NoError(t, s.DeleteUserOAuth(ctx, u.ID))
	got, err = s.ClientsWithAccess(ctx, u.ID, t0)
	require.NoError(t, err)
	assert.Empty(t, got)
}

// A token is written only while its grant's code or refresh token exists, so none can be issued
// after "Remove Claude's access" deleted them (security scan).
func TestTokensNeedTheirGrant(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	code := store.OAuthRequest{
		Signature: "code1", Kind: store.KindCode, RequestID: "req1", ClientID: "cl_1", UserID: u.ID,
		RequestedAt: t0, SessionJSON: []byte(`{}`), ExpiresAt: t0.Add(time.Minute),
	}
	require.NoError(t, s.PutOAuthRequest(ctx, code))
	tok := code
	tok.Signature, tok.Kind = "acc1", store.KindAccess
	require.NoError(t, s.PutOAuthToken(ctx, tok))
	tok.Signature, tok.Kind = "ref1", store.KindRefresh
	require.NoError(t, s.PutOAuthToken(ctx, tok))

	other := tok
	other.Signature, other.RequestID = "ref2", "req-unknown"
	require.ErrorIs(t, s.PutOAuthToken(ctx, other), store.ErrNotFound, "no grant")
	other.RequestID, other.UserID = "req1", "usr_someone_else"
	require.ErrorIs(t, s.PutOAuthToken(ctx, other), store.ErrNotFound, "another user's grant")

	require.NoError(t, s.RevokeOAuthRequests(ctx, store.KindRefresh, "req1", t0))
	tok.Signature = "ref4"
	require.ErrorIs(t, s.PutOAuthToken(ctx, tok), store.ErrNotFound, "a revoked grant gets no new tokens")

	require.NoError(t, s.DeleteUserOAuth(ctx, u.ID))
	tok.Signature = "ref3"
	require.ErrorIs(t, s.PutOAuthToken(ctx, tok), store.ErrNotFound, "after revocation")
	require.Error(t, s.PutOAuthToken(ctx, code), "codes go through PutOAuthRequest")
}

func TestPurgeExpired(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	require.NoError(t, s.CreateSession(ctx, []byte("old"), u.ID, t0, t0.Add(time.Minute)))
	require.NoError(t, s.CreateSession(ctx, []byte("new"), u.ID, t0, t0.Add(time.Hour)))
	require.NoError(t, s.CreateEmailToken(ctx, []byte("old"), u.ID, store.PurposeVerify, t0.Add(time.Minute)))
	require.NoError(t, s.CreatePairingCode(ctx, []byte("old"), u.ID, t0.Add(time.Minute)))
	require.NoError(t, s.PutOAuthRequest(ctx, store.OAuthRequest{
		Signature: "old", Kind: store.KindCode, RequestID: "r", ClientID: "c", UserID: u.ID,
		RequestedAt: t0, SessionJSON: []byte(`{}`), ExpiresAt: t0.Add(time.Minute),
	}))

	require.NoError(t, s.PurgeExpired(ctx, t0.Add(10*time.Minute)))
	_, err := s.Session(ctx, []byte("new"), t0)
	require.NoError(t, err)
	_, err = s.Session(ctx, []byte("old"), t0)
	require.ErrorIs(t, err, store.ErrNotFound)
	_, err = s.OAuthRequest(ctx, store.KindCode, "old")
	require.ErrorIs(t, err, store.ErrNotFound)
}

func TestPurgeUnusedRegisteredClients(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	for _, c := range []store.OAuthClient{
		{ID: "stale-dcr", Kind: "dcr", CreatedAt: t0},
		{ID: "fresh-dcr", Kind: "dcr", CreatedAt: t0.Add(7 * 24 * time.Hour)},
		{ID: "used-dcr", Kind: "dcr", CreatedAt: t0},
		{ID: "https://claude.ai/cimd", Kind: "cimd", CreatedAt: t0, FetchedAt: t0},
		{ID: "https://attacker.example/1", Kind: "cimd", CreatedAt: t0, FetchedAt: t0.Add(6 * 24 * time.Hour)},
		{ID: "https://fresh.example/c", Kind: "cimd", CreatedAt: t0, FetchedAt: t0.Add(8*24*time.Hour - time.Hour)},
	} {
		c.MetadataJSON = []byte(`{}`)
		require.NoError(t, s.PutOAuthClient(ctx, c))
	}
	require.NoError(t, s.PutOAuthRequest(ctx, store.OAuthRequest{
		Signature: "live", Kind: store.KindRefresh, RequestID: "r", ClientID: "used-dcr", UserID: u.ID,
		RequestedAt: t0, SessionJSON: []byte(`{}`), ExpiresAt: t0.Add(90 * 24 * time.Hour),
	}))
	require.NoError(t, s.PutOAuthRequest(ctx, store.OAuthRequest{
		Signature: "live2", Kind: store.KindRefresh, RequestID: "r2", ClientID: "https://claude.ai/cimd", UserID: u.ID,
		RequestedAt: t0, SessionJSON: []byte(`{}`), ExpiresAt: t0.Add(90 * 24 * time.Hour),
	}))

	require.NoError(t, s.PurgeExpired(ctx, t0.Add(8*24*time.Hour)))
	_, err := s.OAuthClient(ctx, "stale-dcr")
	require.ErrorIs(t, err, store.ErrNotFound, "a week-old registration with no live grant goes")
	_, err = s.OAuthClient(ctx, "https://attacker.example/1")
	require.ErrorIs(t, err, store.ErrNotFound, "a cached document fetched over a day ago, with no grant, goes")
	for _, id := range []string{"fresh-dcr", "used-dcr", "https://claude.ai/cimd", "https://fresh.example/c"} {
		_, err = s.OAuthClient(ctx, id)
		require.NoError(t, err, id)
	}
}

// The cache of client metadata documents is capped: beyond the newest few, only documents of
// clients that hold a code or token stay (anyone can make the relay fetch and cache a URL).
func TestCachedClientsAreCapped(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	put := func(id string, at time.Time) {
		t.Helper()
		require.NoError(t, s.PutCachedClient(ctx, store.OAuthClient{ID: id, Kind: "cimd", MetadataJSON: []byte(`{}`), CreatedAt: at, FetchedAt: at}, 3))
	}
	has := func(id string) bool {
		_, err := s.OAuthClient(ctx, id)
		return err == nil
	}
	require.NoError(t, s.PutOAuthClient(ctx, store.OAuthClient{ID: "cl_registered", Kind: "dcr", MetadataJSON: []byte(`{}`), CreatedAt: t0}))
	put("https://claude.ai/doc", t0)
	require.NoError(t, s.PutOAuthRequest(ctx, store.OAuthRequest{
		Signature: "live", Kind: store.KindRefresh, RequestID: "r", ClientID: "https://claude.ai/doc", UserID: u.ID,
		RequestedAt: t0, SessionJSON: []byte(`{}`), ExpiresAt: t0.Add(time.Hour),
	}))
	for i := range 10 {
		put(fmt.Sprintf("https://attacker.example/%d", i), t0.Add(time.Duration(i+1)*time.Second))
	}
	assert.True(t, has("https://claude.ai/doc"), "a client with a grant is never dropped")
	assert.True(t, has("cl_registered"), "registered clients are not part of the cache")
	kept := 0
	for i := range 10 {
		if has(fmt.Sprintf("https://attacker.example/%d", i)) {
			kept++
		}
	}
	assert.Equal(t, 3, kept, "the newest three")
	assert.True(t, has("https://attacker.example/9"))
	assert.False(t, has("https://attacker.example/0"))

	put("https://attacker.example/0", t0) // older than everything kept, but it is the one just fetched
	assert.True(t, has("https://attacker.example/0"), "the document just stored is not dropped by its own cap")
}

// A code can be marked used once; a second marking finds nothing to mark.
func TestCodeIsMarkedUsedOnce(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	require.NoError(t, s.PutOAuthRequest(ctx, store.OAuthRequest{
		Signature: "code", Kind: store.KindCode, RequestID: "r", ClientID: "c", UserID: u.ID,
		RequestedAt: t0, SessionJSON: []byte(`{}`), ExpiresAt: t0.Add(time.Minute),
	}))
	var wg sync.WaitGroup
	var marked atomic.Int32
	for range 8 {
		wg.Go(func() {
			err := s.MarkOAuthRequestUsed(ctx, store.KindCode, "code", t0.Add(time.Second))
			if err == nil {
				marked.Add(1)
				return
			}
			assert.ErrorIs(t, err, store.ErrNotFound)
		})
	}
	wg.Wait()
	assert.EqualValues(t, 1, marked.Load())
	require.ErrorIs(t, s.MarkOAuthRequestUsed(ctx, store.KindCode, "missing", t0), store.ErrNotFound)

	require.NoError(t, s.RevokeGrant(ctx, "r", t0.Add(2*time.Second)))
	got, err := s.OAuthRequest(ctx, store.KindCode, "code")
	require.NoError(t, err)
	assert.Equal(t, t0.Add(2*time.Second), got.RevokedAt)
}

func TestRelayKeys(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	k, err := s.KeyOrCreate(ctx, "hmac", func() ([]byte, error) { return []byte("first"), nil })
	require.NoError(t, err)
	assert.Equal(t, []byte("first"), k)
	k, err = s.KeyOrCreate(ctx, "hmac", func() ([]byte, error) { return []byte("second"), nil })
	require.NoError(t, err)
	assert.Equal(t, []byte("first"), k, "a key is created once")
}

func TestEmailCodes(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	require.NoError(t, s.CreateEmailCode(ctx, u.ID, store.PurposeVerify, []byte("old"), t0.Add(15*time.Minute)))
	require.NoError(t, s.CreateEmailCode(ctx, u.ID, store.PurposeVerify, []byte("new"), t0.Add(15*time.Minute)))
	require.ErrorIs(t, s.CheckEmailCode(ctx, u.ID, store.PurposeVerify, []byte("old"), t0), store.ErrWrongCode, "a new code replaces the old one")
	require.ErrorIs(t, s.CheckEmailCode(ctx, u.ID, store.PurposeRecover, []byte("new"), t0), store.ErrNotFound, "purpose must match")
	require.NoError(t, s.CheckEmailCode(ctx, u.ID, store.PurposeVerify, []byte("new"), t0))
	require.ErrorIs(t, s.CheckEmailCode(ctx, u.ID, store.PurposeVerify, []byte("new"), t0), store.ErrNotFound, "single use")

	require.NoError(t, s.CreateEmailCode(ctx, u.ID, store.PurposeRecover, []byte("c"), t0.Add(15*time.Minute)))
	for range store.MaxCodeAttempts {
		require.ErrorIs(t, s.CheckEmailCode(ctx, u.ID, store.PurposeRecover, []byte("x"), t0), store.ErrWrongCode)
	}
	require.ErrorIs(t, s.CheckEmailCode(ctx, u.ID, store.PurposeRecover, []byte("c"), t0), store.ErrNotFound, "locked after 5 wrong codes")

	require.NoError(t, s.CreateEmailCode(ctx, u.ID, store.PurposeVerify, []byte("e"), t0.Add(time.Minute)))
	require.ErrorIs(t, s.CheckEmailCode(ctx, u.ID, store.PurposeVerify, []byte("e"), t0.Add(2*time.Minute)), store.ErrNotFound, "expired")
}

// Concurrent guesses must not get past the 5-attempt limit, and a right code is used once
// (security scan: the check and the count were separate statements).
func TestEmailCodeAttemptsAreAtomic(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	require.NoError(t, s.CreateEmailCode(ctx, u.ID, store.PurposeRecover, []byte("c"), t0.Add(15*time.Minute)))
	var wrong, used atomic.Int32
	var wg sync.WaitGroup
	for range 40 {
		wg.Go(func() {
			if errors.Is(s.CheckEmailCode(ctx, u.ID, store.PurposeRecover, []byte("x"), t0), store.ErrWrongCode) {
				wrong.Add(1)
			}
		})
	}
	wg.Wait()
	assert.LessOrEqual(t, int(wrong.Load()), store.MaxCodeAttempts, "guesses compared against the code")

	require.NoError(t, s.CreateEmailCode(ctx, u.ID, store.PurposeVerify, []byte("v"), t0.Add(15*time.Minute)))
	for range 20 {
		wg.Go(func() {
			if s.CheckEmailCode(ctx, u.ID, store.PurposeVerify, []byte("v"), t0) == nil {
				used.Add(1)
			}
		})
	}
	wg.Wait()
	assert.Equal(t, int32(1), used.Load(), "a code is used once")
}

// FR-042a: 20 wrong codes for one address within a day refuse every emailed code until the day
// is over; new codes don't reset the count, and right codes don't add to it.
func TestTwentyWrongCodesADay(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	at := t0
	for i := range store.MaxWrongCodesPerDay {
		if i%store.MaxCodeAttempts == 0 {
			right := []byte(fmt.Sprintf("v%d", i))
			require.NoError(t, s.CreateEmailCode(ctx, u.ID, store.PurposeRecover, []byte("c"), at.Add(15*time.Minute)))
			require.NoError(t, s.CreateEmailCode(ctx, u.ID, store.PurposeVerify, right, at.Add(15*time.Minute)))
			require.NoError(t, s.CheckEmailCode(ctx, u.ID, store.PurposeVerify, right, at), "a right code doesn't count")
		}
		require.ErrorIs(t, s.CheckEmailCode(ctx, u.ID, store.PurposeRecover, []byte("x"), at), store.ErrWrongCode)
		at = at.Add(time.Minute)
	}
	require.NoError(t, s.CreateEmailCode(ctx, u.ID, store.PurposeRecover, []byte("c"), at.Add(15*time.Minute)))
	assert.True(t, s.EmailCodesLocked(ctx, u.ID, at))
	require.ErrorIs(t, s.CheckEmailCode(ctx, u.ID, store.PurposeRecover, []byte("c"), at), store.ErrCodesLocked, "even the right code")
	require.NoError(t, s.CreateEmailCode(ctx, u.ID, store.PurposeVerify, []byte("v"), at.Add(15*time.Minute)))
	require.ErrorIs(t, s.CheckEmailCode(ctx, u.ID, store.PurposeVerify, []byte("v"), at), store.ErrCodesLocked, "every purpose")

	other, err := s.CreateUser(ctx, "b@example.com", t0)
	require.NoError(t, err)
	assert.False(t, s.EmailCodesLocked(ctx, other.ID, at), "per address")

	dayOver := t0.Add(24 * time.Hour)
	assert.False(t, s.EmailCodesLocked(ctx, u.ID, dayOver))
	require.NoError(t, s.CreateEmailCode(ctx, u.ID, store.PurposeRecover, []byte("c"), dayOver.Add(15*time.Minute)))
	require.ErrorIs(t, s.CheckEmailCode(ctx, u.ID, store.PurposeRecover, []byte("x"), dayOver), store.ErrWrongCode)
	require.NoError(t, s.CheckEmailCode(ctx, u.ID, store.PurposeRecover, []byte("c"), dayOver), "a new day, a new count")
}

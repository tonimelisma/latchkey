package oauth_test

import (
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/oauth"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

const claudeRedirect = "https://claude.ai/api/mcp/auth_callback"

// tokensVia is tokens with a chosen redirect URI.
func (e *env) tokensVia(clientID, redirect string) (access, refresh string) {
	e.t.Helper()
	p := newPKCE()
	loc := e.approve(authorizeURL(clientID, redirect, &p, nil))
	code := loc.Query().Get("code")
	require.NotEmpty(e.t, code, loc.String())
	resp, m := e.tokenRequest(url.Values{
		"grant_type": {"authorization_code"}, "code": {code}, "redirect_uri": {redirect},
		"client_id": {clientID}, "code_verifier": {p.verifier},
	})
	require.Equal(e.t, http.StatusOK, resp.StatusCode, m)
	access, _ = m["access_token"].(string)
	refresh, _ = m["refresh_token"].(string)
	return access, refresh
}

func (e *env) grants() []oauth.Grant {
	e.t.Helper()
	g, err := e.oauth.Grants(ctxT(e.t), e.userID)
	require.NoError(e.t, err)
	return g
}

func (e *env) changes() int {
	e.authorizedMu.Lock()
	defer e.authorizedMu.Unlock()
	n := 0
	for _, id := range e.grantsChanged {
		if id == e.userID {
			n++
		}
	}
	return n
}

func (e *env) removed() []string {
	e.authorizedMu.Lock()
	defer e.authorizedMu.Unlock()
	return append([]string(nil), e.grantsRemoved...)
}

// Each Allow is one entry, also twice for one client, named as the consent page named it
// (FR-190). An approval whose code was never redeemed has no access and is not listed.
func TestGrantsListEachApproval(t *testing.T) {
	e := setup(t)
	id := e.registerNamed("Claude [Team]", claudeRedirect, "http://localhost:7777/callback")
	p := newPKCE()
	e.approve(authorizeURL(id, claudeRedirect, &p, nil))
	assert.Empty(t, e.grants(), "approved, code not redeemed: no access yet")
	assert.Zero(t, e.changes())

	e.tokensVia(id, claudeRedirect)
	assert.Equal(t, 1, e.changes(), "the list changed when the first token was issued")
	e.clock.advance(time.Minute)
	e.tokensVia(id, "http://localhost:51234/callback")
	assert.Equal(t, 2, e.changes())

	got := e.grants()
	require.Len(t, got, 2, "one client, two approvals, two entries")
	assert.Equal(t, "this computer", got[0].Redirect, "newest first; loopback is this computer")
	assert.Equal(t, "localhost", got[0].Host)
	assert.Equal(t, "claude.ai", got[1].Redirect)
	assert.Equal(t, "claude.ai", got[1].Host)
	assert.Equal(t, "Claude Team", got[1].Name, "cleaned exactly as on the consent page")
	assert.Equal(t, "Claude Team (claude.ai)", got[1].Label())
	assert.WithinDuration(t, e.clock.now().Add(-time.Minute), got[1].ApprovedAt, time.Second)
	assert.True(t, got[1].LastUsedAt.IsZero())
	for _, g := range got {
		assert.Regexp(t, `^[A-Za-z0-9_-]{1,64}$`, g.ID)
		assert.NotEqual(t, id, g.ID, "not the client ID")
	}
	assert.NotEqual(t, got[0].ID, got[1].ID)

	other, err := e.oauth.Grants(ctxT(t), "usr_nobody")
	require.NoError(t, err)
	assert.Empty(t, other)
}

// A client that gave no name is listed with the relay's words for it, never an empty name.
func TestGrantOfAnUnnamedClient(t *testing.T) {
	e := setup(t)
	id := e.registerNamed("", claudeRedirect)
	e.tokensVia(id, claudeRedirect)
	got := e.grants()
	require.Len(t, got, 1)
	assert.Equal(t, "An unnamed app", got[0].Name)
}

// Removing one grant ends exactly that one: its access token and refresh token stop working,
// the other approval of the same client keeps working, and an ID from another account or an
// unknown one changes nothing (FR-191).
func TestRevokeGrantEndsExactlyThatGrant(t *testing.T) {
	e := setup(t)
	id := e.register(claudeRedirect)
	accessA, refreshA := e.tokens(id)
	e.clock.advance(time.Second)
	accessB, refreshB := e.tokens(id)
	got := e.grants()
	require.Len(t, got, 2)
	a, b := got[1], got[0]
	before := e.changes()

	removed, err := e.oauth.RevokeGrant(ctxT(t), "usr_someone_else", a.ID, "test")
	require.NoError(t, err)
	assert.False(t, removed, "another account can't remove it")
	removed, err = e.oauth.RevokeGrant(ctxT(t), e.userID, "grt_unknown", "test")
	require.NoError(t, err)
	assert.False(t, removed)
	assert.Equal(t, http.StatusOK, e.mcpStatus(accessA))
	assert.Empty(t, e.removed())

	removed, err = e.oauth.RevokeGrant(ctxT(t), e.userID, a.ID, "test")
	require.NoError(t, err)
	assert.True(t, removed)
	assert.Equal(t, http.StatusUnauthorized, e.mcpStatus(accessA), "the removed grant is refused at once")
	assert.Equal(t, http.StatusOK, e.mcpStatus(accessB), "the other grant keeps working")
	resp, m := e.tokenRequest(url.Values{"grant_type": {"refresh_token"}, "refresh_token": {refreshA}, "client_id": {id}})
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	assert.Equal(t, "invalid_grant", m["error"])
	resp, _ = e.tokenRequest(url.Values{"grant_type": {"refresh_token"}, "refresh_token": {refreshB}, "client_id": {id}})
	assert.Equal(t, http.StatusOK, resp.StatusCode, "and can still refresh")

	left := e.grants()
	require.Len(t, left, 1)
	assert.Equal(t, b.ID, left[0].ID, "the ID is stable across a refresh")
	assert.Equal(t, []string{a.ID}, e.removed(), "its open sessions are to be closed")
	assert.Equal(t, before+1, e.changes())
}

// A client's own /revoke, and a refresh token used again after its grace window, end the grant;
// both are reported so the Mac's list follows. An ordinary refresh reports nothing.
func TestGrantsChangeWhenAClientRevokesOrATokenIsReused(t *testing.T) {
	e := setup(t)
	id := e.register(claudeRedirect)
	_, refresh := e.tokens(id)
	e.clock.advance(time.Second)
	_, refresh2 := e.tokens(id)
	require.Len(t, e.grants(), 2)
	first, second := e.grants()[1], e.grants()[0]

	before := e.changes()
	resp, m := e.tokenRequest(url.Values{"grant_type": {"refresh_token"}, "refresh_token": {refresh}, "client_id": {id}})
	require.Equal(t, http.StatusOK, resp.StatusCode, m)
	assert.Equal(t, before, e.changes(), "a refresh doesn't change the list")
	assert.Empty(t, e.removed())
	require.Len(t, e.grants(), 2)

	// Reuse of the rotated token after the grace window revokes its grant.
	e.clock.advance(2 * time.Minute)
	resp, _ = e.tokenRequest(url.Values{"grant_type": {"refresh_token"}, "refresh_token": {refresh}, "client_id": {id}})
	require.Equal(t, http.StatusBadRequest, resp.StatusCode)
	left := e.grants()
	require.Len(t, left, 1)
	assert.Equal(t, second.ID, left[0].ID)
	assert.Greater(t, e.changes(), before)
	assert.Equal(t, []string{first.ID}, e.removed())

	// The client revokes the other one itself.
	before = e.changes()
	r := e.do(http.MethodPost, "/revoke", strings.NewReader(url.Values{"token": {refresh2}, "client_id": {id}}.Encode()),
		"application/x-www-form-urlencoded", false)
	require.Equal(t, http.StatusOK, r.StatusCode)
	assert.Empty(t, e.grants())
	assert.Greater(t, e.changes(), before)
	assert.Equal(t, []string{first.ID, second.ID}, e.removed())
}

// "Remove Claude's access" (and a recovery, which calls the same) empties the list and says so.
func TestRevokeUserReportsTheChange(t *testing.T) {
	e := setup(t)
	id := e.register(claudeRedirect)
	e.tokens(id)
	before := e.changes()
	require.NoError(t, e.oauth.RevokeUser(ctxT(t), e.userID, "test"))
	assert.Empty(t, e.grants())
	assert.Equal(t, before+1, e.changes())
}

// When a grant was last used is written at most once a minute, not on every request (FR-192).
func TestLastUsedIsWrittenAtMostOnceAMinute(t *testing.T) {
	e := setup(t)
	id := e.register(claudeRedirect)
	access, _ := e.tokens(id)
	require.True(t, e.grants()[0].LastUsedAt.IsZero())

	start := e.clock.now()
	require.Equal(t, http.StatusOK, e.mcpStatus(access))
	first := e.grants()[0].LastUsedAt
	assert.WithinDuration(t, start, first, time.Second)

	e.clock.advance(30 * time.Second)
	require.Equal(t, http.StatusOK, e.mcpStatus(access))
	assert.Equal(t, first, e.grants()[0].LastUsedAt, "not written again within the minute")

	e.clock.advance(31 * time.Second)
	before := e.changes()
	require.Equal(t, http.StatusOK, e.mcpStatus(access))
	assert.WithinDuration(t, start.Add(61*time.Second), e.grants()[0].LastUsedAt, time.Second)
	assert.Equal(t, before, e.changes(), "a last-used time alone is not a change of the list")
}

// The bearer check tells the MCP layer which grant a request belongs to, by its public ID.
func TestTokenInfoNamesTheGrant(t *testing.T) {
	e := setup(t)
	id := e.register(claudeRedirect)
	access, _ := e.tokens(id)
	info, err := e.oauth.Verify(ctxT(t), access)
	require.NoError(t, err)
	assert.Equal(t, e.grants()[0].ID, info.Extra[oauth.GrantExtra])
}

// A token from before grants were recorded (its grant has an empty label, as migration 10
// writes it) is listed with what the relay knows of its client.
func TestGrantWithoutAStoredLabelIsNamedFromItsClient(t *testing.T) {
	e := setup(t)
	id := e.registerNamed("Claude", claudeRedirect)
	now := e.clock.now()
	require.NoError(t, e.store.PutOAuthRequest(ctxT(t), store.OAuthRequest{
		Signature: "legacy-refresh", Kind: store.KindRefresh, RequestID: "req-legacy", ClientID: id, UserID: e.userID,
		RequestedAt: now, SessionJSON: []byte(`{}`), ExpiresAt: now.Add(time.Hour),
	}))
	require.NoError(t, e.store.AddGrant(ctxT(t), store.Grant{
		RequestID: "req-legacy", ID: store.NewGrantID(), UserID: e.userID, ClientID: id, ApprovedAt: now,
	}))
	got := e.grants()
	require.Len(t, got, 1)
	assert.Equal(t, "Claude", got[0].Name)
	assert.Equal(t, "claude.ai", got[0].Host)
	assert.Equal(t, "claude.ai", got[0].Redirect)
}

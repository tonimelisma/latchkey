package oauth_test

import (
	"context"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/oauth"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// fositeFixture is a grant made by the relay while it used fosite (testdata, written by that
// version): its database rows, its signing key, and the tokens Claude holds.
type fositeFixture struct {
	MadeAtMS            int64    `json:"made_at_ms"`
	HMACHex             string   `json:"oauth_hmac_hex"`
	ClientID            string   `json:"client_id"`
	RedirectURI         string   `json:"redirect_uri"`
	UserID              string   `json:"user_id"`
	AccessToken         string   `json:"access_token"`
	RefreshToken        string   `json:"refresh_token"`
	RotatedRefreshToken string   `json:"rotated_refresh_token"`
	UsedCode            string   `json:"used_code"`
	SQL                 []string `json:"sql"`
}

// setupFromFosite starts the relay on a database holding the fixture's grant, with the clock at
// the moment the fixture was made.
func setupFromFosite(t *testing.T) (*env, fositeFixture) {
	t.Helper()
	ctx := context.Background()
	b, err := os.ReadFile("testdata/fosite-0.49-grant.json")
	require.NoError(t, err)
	var f fositeFixture
	require.NoError(t, json.Unmarshal(b, &f))
	secret, err := hex.DecodeString(f.HMACHex)
	require.NoError(t, err)

	path := filepath.Join(t.TempDir(), "relay.db")
	st, err := store.Open(ctx, path) // today's schema
	require.NoError(t, err)
	_, err = st.KeyOrCreate(ctx, "oauth_hmac", func() ([]byte, error) { return secret, nil })
	require.NoError(t, err)
	require.NoError(t, st.Close())
	raw, err := sql.Open("sqlite", "file:"+path)
	require.NoError(t, err)
	for _, q := range f.SQL {
		_, err := raw.ExecContext(ctx, q)
		require.NoError(t, err, q)
	}
	require.NoError(t, raw.Close())

	e := setupAt(t, path, oauth.AnyClientHost())
	require.Equal(t, f.UserID, e.userID)
	e.clock.mu.Lock()
	e.clock.t = time.UnixMilli(f.MadeAtMS).Add(time.Second)
	e.clock.mu.Unlock()
	return e, f
}

// Claude stays connected across the move from fosite to zitadel/oidc: the access token, the
// refresh token, and the grant the fosite version issued keep working, and its rotated refresh
// token is still caught when it comes back (FR-188, FR-190).
func TestFositeGrantCarriesOver(t *testing.T) {
	e, f := setupFromFosite(t)
	assert.Equal(t, http.StatusOK, e.mcpStatus(f.AccessToken), "the access token Claude holds")
	got := e.grants()
	require.Len(t, got, 1)
	assert.Equal(t, "Claude (claude.ai)", got[0].Label())

	resp, m := e.tokenRequest(url.Values{"grant_type": {"refresh_token"}, "refresh_token": {f.RefreshToken}, "client_id": {f.ClientID}})
	require.Equal(t, http.StatusOK, resp.StatusCode, m)
	access, _ := m["access_token"].(string)
	refresh, _ := m["refresh_token"].(string)
	assert.Equal(t, http.StatusOK, e.mcpStatus(access), "the new access token")
	assert.NotEqual(t, f.RefreshToken, refresh, "rotated")
	require.Len(t, e.grants(), 1, "still one grant: the same approval")
	assert.Equal(t, got[0].ID, e.grants()[0].ID)

	// The token the fosite version rotated, presented after its grace: the grant ends.
	e.clock.advance(2 * time.Minute)
	resp, m = e.tokenRequest(url.Values{"grant_type": {"refresh_token"}, "refresh_token": {f.RotatedRefreshToken}, "client_id": {f.ClientID}})
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	assert.Equal(t, "invalid_grant", m["error"])
	assert.Equal(t, http.StatusUnauthorized, e.mcpStatus(access))
	assert.Empty(t, e.grants())
}

// A code the fosite version issued and saw redeemed, presented again, ends its grant (FR-096).
func TestFositeCodeReplayEndsTheGrant(t *testing.T) {
	e, f := setupFromFosite(t)
	p := newPKCE()
	resp, m := e.tokenRequest(url.Values{
		"grant_type": {"authorization_code"}, "code": {f.UsedCode}, "redirect_uri": {f.RedirectURI},
		"client_id": {f.ClientID}, "code_verifier": {p.verifier},
	})
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	assert.Equal(t, "invalid_grant", m["error"])
	assert.Equal(t, http.StatusUnauthorized, e.mcpStatus(f.AccessToken))
}

// The client revokes a fosite-era refresh token itself (RFC 7009).
func TestFositeTokenRevoked(t *testing.T) {
	e, f := setupFromFosite(t)
	r := e.do(http.MethodPost, "/revoke", strings.NewReader(url.Values{"token": {f.RefreshToken}, "client_id": {f.ClientID}}.Encode()),
		"application/x-www-form-urlencoded", false)
	assert.Equal(t, http.StatusOK, r.StatusCode)
	assert.Equal(t, http.StatusUnauthorized, e.mcpStatus(f.AccessToken))
	assert.Empty(t, e.grants())
}

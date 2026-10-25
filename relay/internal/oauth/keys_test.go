package oauth_test

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"database/sql"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/oauth"
)

// Access given to Claude before the relay's keys were encrypted keeps working after: tokens
// issued by a relay whose database held the signing key as it is (an earlier version) are
// accepted once that database has been converted (FR-188).
func TestTokensIssuedBeforeKeysWereEncryptedStillWork(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	dbPath, keyFile := filepath.Join(dir, "relay.db"), filepath.Join(dir, "relay.key")

	before := setupAt(t, dbPath, oauth.AnyClientHost())
	id := before.register("https://claude.ai/api/mcp/auth_callback")
	access, refresh := before.tokens(id)
	require.Equal(t, http.StatusOK, before.mcpStatus(access))
	before.srv.Close()
	require.NoError(t, before.store.Close())

	// The database as an earlier version left it: the signing key as it is, and no key file.
	key, err := os.ReadFile(keyFile)
	require.NoError(t, err)
	block, err := aes.NewCipher(key)
	require.NoError(t, err)
	aead, err := cipher.NewGCM(block)
	require.NoError(t, err)
	raw, err := sql.Open("sqlite", "file:"+dbPath)
	require.NoError(t, err)
	var sealed []byte
	require.NoError(t, raw.QueryRowContext(ctx, `SELECT value FROM relay_keys WHERE name = 'oauth_hmac' AND format = 1`).Scan(&sealed))
	plain, err := aead.Open(nil, sealed[:12], sealed[12:], []byte("oauth_hmac"))
	require.NoError(t, err)
	require.Len(t, plain, 32)
	_, err = raw.ExecContext(ctx, `UPDATE relay_keys SET value = ?, format = 0 WHERE name = 'oauth_hmac'`, plain)
	require.NoError(t, err)
	require.NoError(t, raw.Close())
	require.NoError(t, os.Remove(keyFile))

	// This version starts on it: a new key file, the key sealed, the same tokens still good.
	after := setupAt(t, dbPath, oauth.AnyClientHost())
	_, created := after.store.KeyFileCreated()
	require.True(t, created, "a new key file was made")
	assert.Equal(t, http.StatusOK, after.mcpStatus(access), "an access token from before the conversion is accepted")
	resp, m := after.tokenRequest(url.Values{"grant_type": {"refresh_token"}, "refresh_token": {refresh}, "client_id": {id}})
	assert.Equal(t, http.StatusOK, resp.StatusCode, m)
	assert.Equal(t, http.StatusUnauthorized, after.mcpStatus(access+"x"))
}

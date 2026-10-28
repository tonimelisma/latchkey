package oauth_test

import (
	"context"
	"database/sql"
	"net/http"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/oauth"
)

// An access token works only while its client does (FR-180, FR-095; security review of the
// move to zitadel/oidc): the bearer check looks the client up as every token read does, so a
// token whose registered client is gone, or whose metadata document can no longer be used, is
// refused on /mcp.
func TestAccessTokenOfAClientThatIsGoneIsRefused(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay.db")
	e := setupAt(t, path, oauth.AnyClientHost())
	registered := e.register("https://claude.ai/api/mcp/auth_callback")
	dcrAccess, _ := e.tokens(registered)
	doc := newCIMDServer(t)
	fetched := doc.URL + "/client.json"
	cimdAccess, _ := e.tokens(fetched)
	require.Equal(t, http.StatusOK, e.mcpStatus(dcrAccess))
	require.Equal(t, http.StatusOK, e.mcpStatus(cimdAccess))

	// Both client rows disappear (a registration removed; the cached document gone) and the
	// document's host fails, while the tokens' rows stay.
	raw, err := sql.Open("sqlite", "file:"+path)
	require.NoError(t, err)
	_, err = raw.ExecContext(context.Background(), `DELETE FROM oauth_clients`)
	require.NoError(t, err)
	require.NoError(t, raw.Close())
	doc.set(true, "")
	e.clock.advance(time.Second)

	assert.Equal(t, http.StatusUnauthorized, e.mcpStatus(dcrAccess), "the registered client is gone")
	assert.Equal(t, http.StatusUnauthorized, e.mcpStatus(cimdAccess), "the metadata document can't be used")
}

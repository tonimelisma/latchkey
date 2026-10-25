package oauth_test

import (
	"context"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/oauth"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

const onlyClaude = "This relay only accepts Claude's apps."

func hosts(t *testing.T, list string) oauth.AllowedHosts {
	t.Helper()
	a, err := oauth.ParseAllowedHosts(list)
	require.NoError(t, err)
	return a
}

func body(t *testing.T, resp *http.Response) string {
	t.Helper()
	b, err := io.ReadAll(resp.Body)
	require.NoError(t, err)
	return string(b)
}

// A client whose metadata document is on a listed host is accepted, and may send the browser
// back to the Owner's own computer, as Claude Code does (FR-180, FR-181).
func TestAllowedClientHostAccepted(t *testing.T) {
	e := setupAllowing(t, hosts(t, "127.0.0.1")) // the test's document host
	p := newPKCE()
	resp := e.do(http.MethodGet, authorizeURL(e.cimd.URL+"/oauth/client.json", "http://localhost:51234/callback", &p, nil), nil, "", true)
	require.Equal(t, http.StatusOK, resp.StatusCode, "consent page")
	assert.Equal(t, 1, e.auth.consentCount())
}

// A client on any other host is refused in words, with no redirect, and the relay never asks
// that host for anything (FR-183).
func TestOtherClientHostRefusedWithoutFetch(t *testing.T) {
	e := setupAllowing(t, oauth.AllowedHosts{}) // the default: Claude's apps
	doc := newCIMDServer(t)
	id := doc.URL + "/client.json"

	resp := e.authorizeStatus(id)
	assert.Equal(t, http.StatusUnauthorized, resp.StatusCode)
	assert.Empty(t, resp.Header.Get("Location"), "no redirect to the refused client")
	assert.Contains(t, body(t, resp), onlyClaude)
	assert.Zero(t, e.auth.consentCount(), "the Owner is not asked")

	tokenResp, m := e.tokenRequest(url.Values{"grant_type": {"refresh_token"}, "refresh_token": {"x"}, "client_id": {id}})
	assert.Equal(t, http.StatusUnauthorized, tokenResp.StatusCode)
	assert.Equal(t, "invalid_client", m["error"])
	assert.Contains(t, m["error_description"], onlyClaude)

	assert.Equal(t, onlyClaude, e.oauth.ClientLookupHint(ctxT(t), id))
	assert.Zero(t, doc.fetched(), "no request to a host that isn't on the list")
}

// A document on a listed host that sends codes to another host is refused (FR-181).
func TestRedirectOnOtherHostRefused(t *testing.T) {
	e := setupAllowing(t, hosts(t, "127.0.0.1"))
	doc := newCIMDServer(t) // its redirect URI is on claude.ai
	resp := e.authorizeStatus(doc.URL + "/client.json")
	assert.Equal(t, http.StatusUnauthorized, resp.StatusCode)
	assert.Empty(t, resp.Header.Get("Location"))
	assert.Contains(t, body(t, resp), "This relay only accepts apps from 127.0.0.1.")
	assert.Zero(t, e.auth.consentCount())

	both := setupAllowing(t, hosts(t, "claude.ai, 127.0.0.1"))
	assert.Equal(t, http.StatusOK, both.authorizeStatus(doc.URL+"/client.json").StatusCode, "with claude.ai listed too")
}

// Registration on request is off unless every host is allowed (FR-182).
func TestRegistrationOffByDefault(t *testing.T) {
	e := setupAllowing(t, oauth.AllowedHosts{})
	reg := `{"client_name":"Claude","redirect_uris":["https://claude.ai/api/mcp/auth_callback"],"token_endpoint_auth_method":"none"}`
	resp := e.do(http.MethodPost, "/register", strings.NewReader(reg), "application/json", false)
	assert.Equal(t, http.StatusForbidden, resp.StatusCode)
	assert.Equal(t, "application/json", resp.Header.Get("Content-Type"))
	m := decode(t, resp)
	assert.Equal(t, "access_denied", m["error"])
	assert.Contains(t, m["error_description"], onlyClaude)

	open := setupAllowing(t, hosts(t, "*"))
	assert.NotEmpty(t, open.register("https://claude.ai/api/mcp/auth_callback"), "on with *")
}

// Without registration the metadata names no registration address, and keeps the two signals
// that make Claude identify itself with a metadata document (FR-182).
func TestMetadataWithoutRegistrationByDefault(t *testing.T) {
	e := setupAllowing(t, oauth.AllowedHosts{})
	m := decode(t, e.do(http.MethodGet, "/.well-known/oauth-authorization-server", nil, "", false))
	assert.NotContains(t, m, "registration_endpoint")
	assert.Equal(t, true, m["client_id_metadata_document_supported"])
	assert.Equal(t, []any{"none"}, m["token_endpoint_auth_methods_supported"])
	assert.Equal(t, []any{"S256"}, m["code_challenge_methods_supported"])
}

// Clients stored while the list was wider stop working and are deleted with their codes and
// tokens, at start and at each purge (FR-184).
func TestStoredClientsOutsideTheListArePurged(t *testing.T) {
	e := setup(t) // any host
	ctx := ctxT(t)
	registered := e.register("https://claude.ai/api/mcp/auth_callback")
	access, _ := e.tokens(registered)
	require.Equal(t, http.StatusOK, e.mcpStatus(access))
	doc := newCIMDServer(t)
	fetched := doc.URL + "/client.json"
	e.tokens(fetched)
	held, err := e.store.ClientsWithAccess(ctx, e.userID, e.clock.now())
	require.NoError(t, err)
	require.Len(t, held, 2)

	// The relay starts again with the default list.
	issuer, _ := url.Parse(e.srv.URL)
	strict, err := oauth.New(ctx, oauth.Config{Issuer: issuer, Store: e.store, Auth: e.auth, HTTPClient: e.cimd.Client(), Now: e.clock.now})
	require.NoError(t, err)
	held, err = e.store.ClientsWithAccess(ctx, e.userID, e.clock.now())
	require.NoError(t, err)
	assert.Empty(t, held, "their tokens are gone")
	for _, id := range []string{registered, fetched} {
		_, err := e.store.OAuthClient(ctx, id)
		require.ErrorIs(t, err, store.ErrNotFound, id)
	}

	// One that appears later (a restored row, say) is refused at once and removed by the purge.
	require.NoError(t, e.store.PutOAuthClient(ctx, store.OAuthClient{
		ID: "cl_old", Kind: "dcr", CreatedAt: e.clock.now(),
		MetadataJSON: []byte(`{"redirect_uris":["https://claude.ai/api/mcp/auth_callback"]}`),
	}))
	assert.Equal(t, onlyClaude, strict.ClientLookupHint(ctx, "cl_old"))
	n, err := strict.PurgeRefusedClients(ctx)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	_, err = e.store.OAuthClient(ctx, "cl_old")
	assert.ErrorIs(t, err, store.ErrNotFound)
}

// With every host allowed nothing is purged.
func TestNothingPurgedWhenEveryHostIsAllowed(t *testing.T) {
	e := setup(t)
	id := e.register("https://claude.ai/api/mcp/auth_callback")
	n, err := e.oauth.PurgeRefusedClients(context.Background())
	require.NoError(t, err)
	assert.Zero(t, n)
	_, err = e.store.OAuthClient(context.Background(), id)
	assert.NoError(t, err)
}

func TestParseAllowedHosts(t *testing.T) {
	for _, c := range []struct {
		in   string
		want []string
	}{
		{"", []string{"claude.ai"}},
		{"claude.ai", []string{"claude.ai"}},
		{" Claude.AI , example.com,", []string{"claude.ai", "example.com"}},
		{"bücher.example", []string{"xn--bcher-kva.example"}},
		{"127.0.0.1", []string{"127.0.0.1"}},
		{"claude.ai,claude.ai", []string{"claude.ai"}},
		{"*", []string{"*"}},
	} {
		a, err := oauth.ParseAllowedHosts(c.in)
		require.NoError(t, err, c.in)
		assert.Equal(t, c.want, a.Strings(), "%q", c.in)
	}
	for _, bad := range []string{
		"https://claude.ai", "claude.ai/oauth", "*.claude.ai", "*,claude.ai", "claude.ai:443",
		",", " , ", "clau de.ai", "claude.ai;example.com", "user@claude.ai", "-bad-.example", "a..b",
	} {
		_, err := oauth.ParseAllowedHosts(bad)
		assert.Error(t, err, "%q", bad)
	}
}

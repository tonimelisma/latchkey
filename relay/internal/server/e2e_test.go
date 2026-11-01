package server

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/auth"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/modelcontextprotocol/go-sdk/oauthex"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/account"
	"github.com/tonimelisma/latchkey/relay/internal/e2e"
	"github.com/tonimelisma/latchkey/relay/internal/oauth"
	"github.com/tonimelisma/latchkey/relay/internal/store"
	"github.com/tonimelisma/latchkey/relay/internal/testagent"
)

var codeRE = regexp.MustCompile(`\b\d{6}\b`)

// startRelay runs the fully assembled relay on localhost.
func startRelay(t *testing.T) (base string, mail *account.MemoryMailer) {
	t.Helper()
	mail = &account.MemoryMailer{}
	base, _ = startRelayWith(t, func(o *Options) { o.Mailer = mail })
	return base, mail
}

// startRelayWith runs the assembled relay with other options, and returns its database too.
func startRelayWith(t *testing.T, tweak func(*Options)) (string, *store.Store) {
	t.Helper()
	ctx := context.Background()
	db, err := store.Open(ctx, filepath.Join(t.TempDir(), "relay.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	srv := httptest.NewUnstartedServer(nil)
	_, port, _ := net.SplitHostPort(srv.Listener.Addr().String())
	base := "http://localhost:" + port
	public, _ := url.Parse(base)
	o := Options{PublicURL: public, Store: db, Logger: slog.Default(), AllowedClients: oauth.AnyClientHost()}
	tweak(&o)
	r, err := New(ctx, o)
	require.NoError(t, err)
	srv.Config.Handler = r.Handler
	srv.Start()
	t.Cleanup(func() { r.Hub.Close(); srv.Close() })
	return base, db
}

func codeFrom(mail *account.MemoryMailer) func(string) (string, error) {
	return func(email string) (string, error) {
		msgs := mail.Sent()
		for i := len(msgs) - 1; i >= 0; i-- {
			if msgs[i].To == email {
				return codeRE.FindString(msgs[i].Body), nil
			}
		}
		return "", errors.New("no email sent")
	}
}

// A relay with no email server, as Claude Code sets one up (spec 009): claimed in real Chrome with
// its setup code, then recovered with a code from the operator's command.
func TestClaimAndRecoverInBrowser(t *testing.T) {
	if testing.Short() {
		t.Skip("browser test")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	b, err := e2e.NewBrowser(ctx)
	if errors.Is(err, e2e.ErrNoChrome) {
		t.Skip("Chrome is not installed; set CHROME_PATH to run the browser test")
	}
	require.NoError(t, err)
	defer b.Close()

	base, db := startRelayWith(t, func(o *Options) { o.SetupCode = "K7PQ-M2XD-9RTA" })
	require.NoError(t, b.Claim(base, "owner@example.com", "k7pq-m2xd-9rta"), "claim with the setup code")
	require.NoError(t, b.SignOut())

	code, err := account.RecoveryCode(ctx, db, "owner@example.com", time.Now())
	require.NoError(t, err)
	require.NoError(t, b.RecoverWithCode(base, code), "recover with the operator's code")
}

// TestEndToEndInBrowser is the Owner's whole first-run path in real Chrome with a passkey:
// sign up, connect Claude (a real MCP client doing OAuth), pair a Mac, call battery_status.
func TestEndToEndInBrowser(t *testing.T) {
	if testing.Short() {
		t.Skip("browser test")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	b, err := e2e.NewBrowser(ctx)
	if errors.Is(err, e2e.ErrNoChrome) {
		t.Skip("Chrome is not installed; set CHROME_PATH to run the browser test")
	}
	require.NoError(t, err)
	defer b.Close()

	base, mail := startRelay(t)
	require.NoError(t, b.SignUp(base, "owner@example.com", codeFrom(mail)), "sign up with a passkey")
	require.NoError(t, b.SignOut())
	require.NoError(t, b.SignIn(base), "sign in with the passkey")

	// Claude connects: discovery, registration, consent in the browser, token exchange.
	cb, err := e2e.NewCallback(ctx)
	require.NoError(t, err)
	defer cb.Close()
	consents := 0
	handler, err := auth.NewAuthorizationCodeHandler(&auth.AuthorizationCodeHandlerConfig{
		RedirectURL: cb.URL,
		DynamicClientRegistrationConfig: &auth.DynamicClientRegistrationConfig{Metadata: &oauthex.ClientRegistrationMetadata{
			ClientName: "Claude", RedirectURIs: []string{cb.URL}, TokenEndpointAuthMethod: "none",
		}},
		RequestRefreshToken: true,
		AuthorizationCodeFetcher: func(_ context.Context, args *auth.AuthorizationArgs) (*auth.AuthorizationResult, error) {
			consents++
			loc, err := b.Approve(base, args.URL, cb.URL)
			if err != nil {
				return nil, err
			}
			q := loc.Query()
			return &auth.AuthorizationResult{Code: q.Get("code"), State: q.Get("state"), Iss: q.Get("iss")}, nil
		},
	})
	require.NoError(t, err)
	client := mcp.NewClient(&mcp.Implementation{Name: "claude-e2e", Version: "1"}, nil)
	cs, err := client.Connect(ctx, &mcp.StreamableClientTransport{Endpoint: base + "/mcp", OAuthHandler: handler, MaxRetries: -1},
		&mcp.ClientSessionOptions{ProtocolVersion: "2025-11-25"})
	require.NoError(t, err)
	defer func() { _ = cs.Close() }()
	assert.Equal(t, 1, consents)

	tools, err := cs.ListTools(ctx, nil)
	require.NoError(t, err)
	assert.Empty(t, tools.Tools, "no Mac yet, no tools")

	// Pair the pretend Mac through the pairing page.
	code, err := b.PairCode(base, "Test MacBook")
	require.NoError(t, err)
	agent := testagent.New("ws"+strings.TrimPrefix(base, "http")+"/agent/v1", "")
	agent.DeviceID, err = e2e.ExchangePairingCode(ctx, base, code, agent.PublicKeyDER(), "Test MacBook")
	require.NoError(t, err)
	conn, err := agent.Dial(ctx)
	require.NoError(t, err)

	require.Eventually(t, func() bool {
		tools, err := cs.ListTools(ctx, nil)
		return err == nil && slices.ContainsFunc(tools.Tools, func(t *mcp.Tool) bool { return t.Name == "battery_status" })
	}, 10*time.Second, 50*time.Millisecond, "battery_status appears once the Mac connects")

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "battery_status", Arguments: map[string]any{}})
	require.NoError(t, err)
	assert.False(t, res.IsError)
	assert.Contains(t, textOf(res), `"battery_percent":82`)
	assert.Contains(t, textOf(res), "Test MacBook (Mac): online · 82% battery", "the state line rides along (FR-065)")

	// The Mac goes away: Claude gets the offline answer right away.
	require.NoError(t, conn.Close())
	require.Eventually(t, func() bool {
		res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "battery_status", Arguments: map[string]any{}})
		return err == nil && res.IsError && strings.HasPrefix(textOf(res), "Test MacBook is offline.")
	}, 10*time.Second, 50*time.Millisecond)
}

func textOf(res *mcp.CallToolResult) string {
	var parts []string
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			parts = append(parts, tc.Text)
		}
	}
	return strings.Join(parts, "\n")
}

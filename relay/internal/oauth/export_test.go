package oauth

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/auth"
	"github.com/zitadel/oidc/v3/pkg/oidc"
)

// SetCIMDMinAge changes the minimum cache time of client metadata documents for one test: with
// zero, a document served with no-store is fetched on every lookup, which lets a test act in
// the middle of a token request.
func SetCIMDMinAge(t *testing.T, d time.Duration) {
	t.Helper()
	old := cimdMinAge
	cimdMinAge = d
	t.Cleanup(func() { cimdMinAge = old })
}

// ClientLookupHint is the description of the error a failed client lookup returns to zitadel.
func (s *Server) ClientLookupHint(ctx context.Context, clientID string) string {
	_, err := s.clients.get(ctx, clientID)
	var oe *oidc.Error
	if errors.As(err, &oe) {
		return oe.Description
	}
	return ""
}

// Verify is the bearer check /mcp runs.
func (s *Server) Verify(ctx context.Context, token string) (*auth.TokenInfo, error) {
	return s.verify(ctx, token, nil)
}

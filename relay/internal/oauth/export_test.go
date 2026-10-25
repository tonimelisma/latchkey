package oauth

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/ory/fosite"
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

// ClientLookupHint is the hint of the error a failed client lookup returns to fosite.
func (s *Server) ClientLookupHint(ctx context.Context, clientID string) string {
	_, err := s.clients.get(ctx, clientID)
	var rfc *fosite.RFC6749Error
	if errors.As(err, &rfc) {
		return rfc.HintField
	}
	return ""
}

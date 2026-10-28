package oauth

import (
	"context"

	"github.com/zitadel/oidc/v3/pkg/op"
)

// ReadCode is the storage call zitadel makes first for a code exchange: it reads the code's
// row. It returns what the exchange carries on with.
func (s *Server) ReadCode(ctx context.Context, code string) (op.AuthRequest, error) {
	return s.storage.AuthRequestByCode(ctx, code)
}

// IssueFor is the storage call a code exchange makes last, after zitadel checked PKCE, the
// client and the redirect URI: it uses up the code read by ReadCode and writes the tokens.
func (s *Server) IssueFor(ctx context.Context, req op.AuthRequest) error {
	_, _, _, err := s.storage.CreateAccessAndRefreshTokens(ctx, req, "")
	return err
}

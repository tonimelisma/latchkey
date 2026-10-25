package oauth

import (
	"context"
	"strings"
)

// codeSignature is the part of a code that fosite's HMAC strategy stores its rows under.
func codeSignature(code string) string {
	if _, sig, ok := strings.Cut(code, "."); ok {
		return sig
	}
	return code
}

// testStorage is the adapter fosite uses; it holds no state of its own.
func (s *Server) testStorage() *storage {
	return &storage{st: s.cfg.Store, clients: s.clients, now: s.cfg.Now}
}

// ReadCode is the storage call fosite makes first for a code exchange, and again before it
// writes tokens: it reads the code's row.
func (s *Server) ReadCode(ctx context.Context, code string) error {
	_, err := s.testStorage().GetAuthorizeCodeSession(ctx, codeSignature(code), nil)
	return err
}

// ReadPKCE is the storage call fosite makes second: it reads the code's PKCE challenge, and
// stops the exchange there if it finds none.
func (s *Server) ReadPKCE(ctx context.Context, code string) error {
	_, err := s.testStorage().GetPKCERequestSession(ctx, codeSignature(code), nil)
	return err
}

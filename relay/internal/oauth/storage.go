package oauth

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"strings"
	"time"

	"github.com/ory/fosite"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// refreshGrace is how long a rotated refresh token keeps working, for network retries (plan D4).
const refreshGrace = 60 * time.Second

// storage adapts the store to fosite's storage interfaces. Tokens are stored by their HMAC
// signature only, never raw.
type storage struct {
	st      *store.Store
	clients *clients
	now     func() time.Time
}

func (s *storage) GetClient(ctx context.Context, id string) (fosite.Client, error) {
	return s.clients.get(ctx, id)
}

// Client assertions (private_key_jwt) are not offered.
func (s *storage) ClientAssertionJWTValid(context.Context, string) error { return nil }

func (s *storage) SetClientAssertionJWT(context.Context, string, time.Time) error { return nil }

func (s *storage) put(ctx context.Context, kind, signature string, req fosite.Requester, expires fosite.TokenType) error {
	sess, ok := req.GetSession().(*fosite.DefaultSession)
	if !ok {
		return errors.New("unexpected session type")
	}
	data, err := json.Marshal(sess)
	if err != nil {
		return err
	}
	exp := sess.GetExpiresAt(expires)
	if exp.IsZero() {
		exp = s.now().Add(time.Hour)
	}
	row := store.OAuthRequest{
		Signature: signature, Kind: kind, RequestID: req.GetID(), ClientID: req.GetClient().GetID(),
		UserID: sess.Subject, RequestedAt: req.GetRequestedAt(),
		Scopes: strings.Join(req.GetRequestedScopes(), " "), GrantedScopes: strings.Join(req.GetGrantedScopes(), " "),
		Form: req.GetRequestForm().Encode(), SessionJSON: data, ExpiresAt: exp,
	}
	if kind != store.KindAccess && kind != store.KindRefresh {
		return s.st.PutOAuthRequest(ctx, row)
	}
	// A token is written only while its grant exists, so one issued while the Owner removes
	// Claude's access is refused rather than outliving the removal.
	if err := s.st.PutOAuthToken(ctx, row); errors.Is(err, store.ErrNotFound) {
		return fosite.ErrNotFound
	} else if err != nil {
		return err
	}
	return nil
}

func (s *storage) get(ctx context.Context, kind, signature string) (*fosite.Request, store.OAuthRequest, error) {
	row, err := s.st.OAuthRequest(ctx, kind, signature)
	if errors.Is(err, store.ErrNotFound) {
		return nil, row, fosite.ErrNotFound
	}
	if err != nil {
		return nil, row, err
	}
	client, err := s.clients.get(ctx, row.ClientID)
	if err != nil {
		return nil, row, err
	}
	var sess fosite.DefaultSession
	if err := json.Unmarshal(row.SessionJSON, &sess); err != nil {
		return nil, row, err
	}
	form, err := url.ParseQuery(row.Form)
	if err != nil {
		return nil, row, err
	}
	req := &fosite.Request{
		ID: row.RequestID, RequestedAt: row.RequestedAt, Client: client, Form: form, Session: &sess,
		RequestedScope: fields(row.Scopes), GrantedScope: fields(row.GrantedScopes),
		RequestedAudience: fosite.Arguments{}, GrantedAudience: fosite.Arguments{},
	}
	return req, row, nil
}

func fields(s string) fosite.Arguments { return fosite.Arguments(strings.Fields(s)) }

func (s *storage) CreateAuthorizeCodeSession(ctx context.Context, code string, req fosite.Requester) error {
	return s.put(ctx, store.KindCode, code, req, fosite.AuthorizeCode)
}

func (s *storage) GetAuthorizeCodeSession(ctx context.Context, code string, _ fosite.Session) (fosite.Requester, error) {
	req, row, err := s.get(ctx, store.KindCode, code)
	if err != nil {
		return nil, err
	}
	if !row.UsedAt.IsZero() {
		return req, fosite.ErrInvalidatedAuthorizeCode
	}
	return req, nil
}

func (s *storage) InvalidateAuthorizeCodeSession(ctx context.Context, code string) error {
	return s.st.MarkOAuthRequestUsed(ctx, store.KindCode, code, s.now())
}

func (s *storage) CreatePKCERequestSession(ctx context.Context, signature string, req fosite.Requester) error {
	return s.put(ctx, store.KindPKCE, signature, req, fosite.AuthorizeCode)
}

func (s *storage) GetPKCERequestSession(ctx context.Context, signature string, _ fosite.Session) (fosite.Requester, error) {
	req, _, err := s.get(ctx, store.KindPKCE, signature)
	return req, err
}

func (s *storage) DeletePKCERequestSession(ctx context.Context, signature string) error {
	return s.st.DeleteOAuthRequest(ctx, store.KindPKCE, signature)
}

func (s *storage) CreateAccessTokenSession(ctx context.Context, signature string, req fosite.Requester) error {
	return s.put(ctx, store.KindAccess, signature, req, fosite.AccessToken)
}

func (s *storage) GetAccessTokenSession(ctx context.Context, signature string, _ fosite.Session) (fosite.Requester, error) {
	req, row, err := s.get(ctx, store.KindAccess, signature)
	if err != nil {
		return nil, err
	}
	if !row.RevokedAt.IsZero() {
		return req, fosite.ErrInactiveToken
	}
	return req, nil
}

func (s *storage) DeleteAccessTokenSession(ctx context.Context, signature string) error {
	return s.st.DeleteOAuthRequest(ctx, store.KindAccess, signature)
}

func (s *storage) CreateRefreshTokenSession(ctx context.Context, signature, _ string, req fosite.Requester) error {
	return s.put(ctx, store.KindRefresh, signature, req, fosite.RefreshToken)
}

// GetRefreshTokenSession treats a rotated token as valid during the grace window; after it, or
// once revoked, fosite sees an inactive token and revokes the whole grant (reuse detection).
func (s *storage) GetRefreshTokenSession(ctx context.Context, signature string, _ fosite.Session) (fosite.Requester, error) {
	req, row, err := s.get(ctx, store.KindRefresh, signature)
	if err != nil {
		return nil, err
	}
	if !row.RevokedAt.IsZero() || (!row.RotatedAt.IsZero() && s.now().Sub(row.RotatedAt) > refreshGrace) {
		return req, fosite.ErrInactiveToken
	}
	return req, nil
}

func (s *storage) DeleteRefreshTokenSession(ctx context.Context, signature string) error {
	return s.st.DeleteOAuthRequest(ctx, store.KindRefresh, signature)
}

// RotateRefreshToken fails closed: a token row that disappeared during the exchange (the Owner
// removed Claude's access) ends the refresh.
func (s *storage) RotateRefreshToken(ctx context.Context, requestID, signature string) error {
	if err := s.st.RotateOAuthRequest(ctx, store.KindRefresh, signature, s.now()); errors.Is(err, store.ErrNotFound) {
		return fosite.ErrNotFound
	} else if err != nil {
		return err
	}
	return nil
}

func (s *storage) RevokeRefreshToken(ctx context.Context, requestID string) error {
	return s.st.RevokeOAuthRequests(ctx, store.KindRefresh, requestID, s.now())
}

func (s *storage) RevokeAccessToken(ctx context.Context, requestID string) error {
	return s.st.RevokeOAuthRequests(ctx, store.KindAccess, requestID, s.now())
}

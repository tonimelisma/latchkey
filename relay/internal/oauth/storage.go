package oauth

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"strings"
	"time"

	jose "github.com/go-jose/go-jose/v4"
	"github.com/zitadel/oidc/v3/pkg/oidc"
	"github.com/zitadel/oidc/v3/pkg/op"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Lifetimes (plan D4).
const (
	codeLifetime    = time.Minute
	accessLifetime  = time.Hour
	refreshLifetime = 90 * 24 * time.Hour
	// refreshGrace is how long a rotated refresh token keeps working, for network retries.
	refreshGrace = 60 * time.Second
)

// storage adapts the store to zitadel/oidc's op.Storage. zitadel parses and checks the token and
// revocation requests (client authentication, PKCE, redirect URI, scopes); storage reads and
// writes the codes and tokens, in the oauth_requests table the relay has always used. Codes and
// tokens are stored by their HMAC signature only (tokens.go). Every row of one approval shares
// its request ID: that is the grant (grants.go).
type storage struct {
	st      *store.Store
	clients *clients
	now     func() time.Time
	tokens  hmacTokens
	// revoked is told the request ID of a grant whose tokens were just revoked, so the relay
	// can see whether the grant still has access.
	revoked func(ctx context.Context, requestID string)
}

var _ op.Storage = (*storage)(nil)

func (s *storage) grantRevoked(ctx context.Context, requestID string) {
	if s.revoked != nil {
		s.revoked(ctx, requestID)
	}
}

// codeRequest is a stored authorization code as zitadel's code exchange sees it (op.AuthRequest).
type codeRequest struct {
	row      store.OAuthRequest
	form     url.Values
	granted  []string
	verifier *oidc.CodeChallenge
}

var _ op.AuthRequest = (*codeRequest)(nil)

func (c *codeRequest) GetID() string                         { return c.row.RequestID }
func (c *codeRequest) GetACR() string                        { return "" }
func (c *codeRequest) GetAMR() []string                      { return nil }
func (c *codeRequest) GetAudience() []string                 { return nil }
func (c *codeRequest) GetAuthTime() time.Time                { return c.row.RequestedAt }
func (c *codeRequest) GetClientID() string                   { return c.row.ClientID }
func (c *codeRequest) GetCodeChallenge() *oidc.CodeChallenge { return c.verifier }
func (c *codeRequest) GetNonce() string                      { return "" }
func (c *codeRequest) GetRedirectURI() string                { return c.form.Get("redirect_uri") }
func (c *codeRequest) GetResponseType() oidc.ResponseType    { return oidc.ResponseTypeCode }
func (c *codeRequest) GetResponseMode() oidc.ResponseMode    { return oidc.ResponseModeQuery }
func (c *codeRequest) GetScopes() []string                   { return c.granted }
func (c *codeRequest) GetState() string                      { return c.form.Get("state") }
func (c *codeRequest) GetSubject() string                    { return c.row.UserID }
func (c *codeRequest) Done() bool                            { return true }

// refreshRequest is a stored refresh token as zitadel's refresh exchange sees it
// (op.RefreshTokenRequest).
type refreshRequest struct {
	row    store.OAuthRequest
	scopes []string
}

var _ op.RefreshTokenRequest = (*refreshRequest)(nil)

func (r *refreshRequest) GetAMR() []string            { return nil }
func (r *refreshRequest) GetAudience() []string       { return nil }
func (r *refreshRequest) GetAuthTime() time.Time      { return r.row.RequestedAt }
func (r *refreshRequest) GetClientID() string         { return r.row.ClientID }
func (r *refreshRequest) GetScopes() []string         { return r.scopes }
func (r *refreshRequest) GetSubject() string          { return r.row.UserID }
func (r *refreshRequest) SetCurrentScopes(s []string) { r.scopes = s }

// session is the session_json column, in the shape the relay's earlier versions (fosite's
// DefaultSession) wrote and read, so a row written now still works if the relay is rolled back.
type session struct {
	ExpiresAt map[string]time.Time `json:"expires_at"`
	Username  string               `json:"username"`
	Subject   string               `json:"subject"`
}

func sessionJSON(subject string, expires map[string]time.Time) []byte {
	b, _ := json.Marshal(session{ExpiresAt: expires, Subject: subject}) // never fails
	return b
}

// invalidGrant is what a client is told about a code or token that doesn't work (any more).
func invalidGrant() *oidc.Error {
	return oidc.ErrInvalidGrant().WithDescription("The authorization code or token is no longer valid.")
}

// read returns the row stored under a token's signature, and looks its client up as every
// read of a code or token does: a client the list of allowed hosts now refuses, or whose
// metadata document can't be used, gets nothing.
func (s *storage) read(ctx context.Context, kind, prefix, token string) (store.OAuthRequest, error) {
	sig, ok := s.tokens.signature(prefix, token)
	if !ok {
		return store.OAuthRequest{}, invalidGrant()
	}
	row, err := s.st.OAuthRequest(ctx, kind, sig)
	if errors.Is(err, store.ErrNotFound) {
		return row, invalidGrant()
	}
	if err != nil {
		return row, oidc.ErrServerError().WithParent(err)
	}
	if _, err := s.clients.get(ctx, row.ClientID); err != nil {
		return row, err
	}
	return row, nil
}

// saveCode stores a new authorization code for an approval and returns it.
func (s *storage) saveCode(ctx context.Context, requestID, userID string, cl *client, requested, granted []string, form url.Values) (string, error) {
	code, sig := s.tokens.generate(prefixCode)
	now := s.now().UTC()
	exp := now.Add(codeLifetime)
	err := s.st.PutOAuthRequest(ctx, store.OAuthRequest{
		Signature: sig, Kind: store.KindCode, RequestID: requestID, ClientID: cl.GetID(), UserID: userID,
		RequestedAt: now, Scopes: strings.Join(requested, " "), GrantedScopes: strings.Join(granted, " "),
		Form: form.Encode(), SessionJSON: sessionJSON(userID, map[string]time.Time{"authorize_code": exp}), ExpiresAt: exp,
	})
	return code, err
}

// AuthRequestByCode reads a code for its exchange. A code presented after it was used ends its
// grant (FR-096): every row of the grant is marked revoked, so the tokens the first exchange got
// stop working and none can be written after (store.PutOAuthToken).
func (s *storage) AuthRequestByCode(ctx context.Context, code string) (op.AuthRequest, error) {
	row, err := s.read(ctx, store.KindCode, prefixCode, code)
	if err != nil {
		return nil, err
	}
	if !row.UsedAt.IsZero() {
		if err := s.st.RevokeGrant(ctx, row.RequestID, s.now()); err != nil {
			return nil, oidc.ErrServerError().WithParent(err)
		}
		s.grantRevoked(ctx, row.RequestID)
		return nil, invalidGrant()
	}
	if !row.RevokedAt.IsZero() || !s.now().Before(row.ExpiresAt) {
		return nil, invalidGrant()
	}
	form, err := url.ParseQuery(row.Form)
	if err != nil {
		return nil, oidc.ErrServerError().WithParent(err)
	}
	c := &codeRequest{row: row, form: form, granted: strings.Fields(row.GrantedScopes)}
	if ch := form.Get("code_challenge"); ch != "" {
		c.verifier = &oidc.CodeChallenge{Challenge: ch, Method: oidc.CodeChallengeMethod(form.Get("code_challenge_method"))}
	}
	return c, nil
}

// useCode marks a code used, once. Of two exchanges of one code that both read it unused, only
// one changes the row; the other is told the code was already used, and the whole grant is
// marked revoked, as for a code replayed later: the first exchange's tokens stop working, and
// none can be written after (store.PutOAuthToken).
func (s *storage) useCode(ctx context.Context, row store.OAuthRequest) error {
	err := s.st.MarkOAuthRequestUsed(ctx, store.KindCode, row.Signature, s.now())
	if err == nil {
		return nil
	}
	if !errors.Is(err, store.ErrNotFound) {
		return oidc.ErrServerError().WithParent(err)
	}
	if rerr := s.st.RevokeGrant(ctx, row.RequestID, s.now()); rerr != nil {
		return oidc.ErrServerError().WithParent(rerr)
	}
	s.grantRevoked(ctx, row.RequestID)
	return invalidGrant()
}

// TokenRequestByRefreshToken reads a refresh token for its exchange. A rotated token keeps
// working for refreshGrace; after it, or once revoked, the token's whole grant is revoked
// (reuse detection, RFC 6819 §5.2.2.3) and the client gets invalid_grant.
func (s *storage) TokenRequestByRefreshToken(ctx context.Context, token string) (op.RefreshTokenRequest, error) {
	row, err := s.read(ctx, store.KindRefresh, prefixRefresh, token)
	if err != nil {
		return nil, err
	}
	now := s.now()
	if !row.RevokedAt.IsZero() || (!row.RotatedAt.IsZero() && now.Sub(row.RotatedAt) > refreshGrace) {
		if err := s.revokeGrantTokens(ctx, row.RequestID); err != nil {
			return nil, oidc.ErrServerError().WithParent(err)
		}
		return nil, invalidGrant()
	}
	if !now.Before(row.ExpiresAt) {
		return nil, invalidGrant()
	}
	return &refreshRequest{row: row, scopes: strings.Fields(row.GrantedScopes)}, nil
}

// revokeGrantTokens revokes every access and refresh token of a grant (a client's /revoke, a
// refresh token used again after its grace) and reports a grant left without access.
func (s *storage) revokeGrantTokens(ctx context.Context, requestID string) error {
	if err := s.st.RevokeOAuthRequests(ctx, store.KindRefresh, requestID, s.now()); err != nil {
		return err
	}
	if err := s.st.RevokeOAuthRequests(ctx, store.KindAccess, requestID, s.now()); err != nil {
		return err
	}
	s.grantRevoked(ctx, requestID)
	return nil
}

// CreateAccessToken is the code exchange without offline_access: the code is used up and an
// access token issued.
func (s *storage) CreateAccessToken(ctx context.Context, req op.TokenRequest) (string, time.Time, error) {
	access, _, exp, err := s.issue(ctx, req, "", false)
	return access, exp, err
}

// CreateAccessAndRefreshTokens is a code exchange with offline_access, or a refresh. The access
// token's "ID" is the token itself (see opaqueCrypto); the refresh token is returned as it is.
func (s *storage) CreateAccessAndRefreshTokens(ctx context.Context, req op.TokenRequest, current string) (string, string, time.Time, error) {
	return s.issue(ctx, req, current, true)
}

// issue uses up the code, or rotates the refresh token, and then writes the new tokens. It
// fails closed: a code used meanwhile, a refresh token that disappeared or whose grant was
// revoked or removed during the exchange, gives invalid_grant and no token that works.
func (s *storage) issue(ctx context.Context, req op.TokenRequest, current string, withRefresh bool) (access, refresh string, exp time.Time, err error) {
	var base store.OAuthRequest
	switch r := req.(type) {
	case *codeRequest:
		if err := s.useCode(ctx, r.row); err != nil {
			return "", "", time.Time{}, err
		}
		base = r.row
	case *refreshRequest:
		sig, ok := s.tokens.signature(prefixRefresh, current)
		if !ok {
			return "", "", time.Time{}, invalidGrant()
		}
		if err := s.st.RotateOAuthRequest(ctx, store.KindRefresh, sig, s.now()); errors.Is(err, store.ErrNotFound) {
			return "", "", time.Time{}, invalidGrant()
		} else if err != nil {
			return "", "", time.Time{}, oidc.ErrServerError().WithParent(err)
		}
		base = r.row
	default:
		return "", "", time.Time{}, oidc.ErrUnsupportedGrantType()
	}
	now := s.now().UTC()
	accessExp, refreshExp := now.Add(accessLifetime), now.Add(refreshLifetime)
	expires := map[string]time.Time{"access_token": accessExp}
	if withRefresh {
		expires["refresh_token"] = refreshExp
	}
	row := store.OAuthRequest{
		RequestID: base.RequestID, ClientID: base.ClientID, UserID: base.UserID, RequestedAt: now,
		Scopes: base.Scopes, GrantedScopes: strings.Join(req.GetScopes(), " "),
		SessionJSON: sessionJSON(base.UserID, expires),
	}
	put := func(kind, prefix string, exp time.Time) (string, error) {
		token, sig := s.tokens.generate(prefix)
		r := row
		r.Signature, r.Kind, r.ExpiresAt = sig, kind, exp
		// A token is written only while its grant exists, so one issued while the Owner removes
		// Claude's access is refused rather than outliving the removal.
		if err := s.st.PutOAuthToken(ctx, r); errors.Is(err, store.ErrNotFound) {
			return "", invalidGrant()
		} else if err != nil {
			return "", oidc.ErrServerError().WithParent(err)
		}
		return token, nil
	}
	if access, err = put(store.KindAccess, prefixAccess, accessExp); err != nil {
		return "", "", time.Time{}, err
	}
	if withRefresh {
		if refresh, err = put(store.KindRefresh, prefixRefresh, refreshExp); err != nil {
			return "", "", time.Time{}, err
		}
	}
	return access, refresh, accessExp, nil
}

// activeToken returns the live row of an access token: unrevoked and unexpired.
func (s *storage) activeToken(ctx context.Context, token string) (store.OAuthRequest, error) {
	sig, ok := s.tokens.signature(prefixAccess, token)
	if !ok {
		return store.OAuthRequest{}, store.ErrNotFound
	}
	row, err := s.st.OAuthRequest(ctx, store.KindAccess, sig)
	if err != nil {
		return row, err
	}
	if !row.RevokedAt.IsZero() || !s.now().Before(row.ExpiresAt) {
		return row, store.ErrNotFound
	}
	return row, nil
}

// GetRefreshTokenInfo and RevokeToken serve zitadel's revocation endpoint (RFC 7009). A token
// of another client is refused; an unknown, used up, or already revoked one is fine (200).
// Revoking any token of a grant revokes all of its access and refresh tokens.
func (s *storage) GetRefreshTokenInfo(ctx context.Context, _ string, token string) (string, string, error) {
	if _, ok := s.tokens.signature(prefixRefresh, token); !ok {
		return "", "", op.ErrInvalidRefreshToken
	}
	return "", token, nil
}

func (s *storage) RevokeToken(ctx context.Context, token, _ string, clientID string) *oidc.Error {
	var row store.OAuthRequest
	var err error
	switch {
	case strings.HasPrefix(token, prefixRefresh):
		row, err = s.liveRow(ctx, store.KindRefresh, prefixRefresh, token)
	case strings.HasPrefix(token, prefixAccess):
		row, err = s.liveRow(ctx, store.KindAccess, prefixAccess, token)
	default:
		return nil
	}
	if errors.Is(err, store.ErrNotFound) {
		return nil
	}
	if err != nil {
		return oidc.ErrServerError().WithParent(err)
	}
	if row.ClientID != clientID {
		return oidc.ErrUnauthorizedClient().WithDescription("The token was issued to another client.")
	}
	if err := s.revokeGrantTokens(ctx, row.RequestID); err != nil {
		return oidc.ErrServerError().WithParent(err)
	}
	return nil
}

// liveRow is a code or token's row unless it is revoked, or a refresh token rotated more than
// refreshGrace ago (store.ErrNotFound then).
func (s *storage) liveRow(ctx context.Context, kind, prefix, token string) (store.OAuthRequest, error) {
	sig, ok := s.tokens.signature(prefix, token)
	if !ok {
		return store.OAuthRequest{}, store.ErrNotFound
	}
	row, err := s.st.OAuthRequest(ctx, kind, sig)
	if err != nil {
		return row, err
	}
	if !row.RevokedAt.IsZero() || (!row.RotatedAt.IsZero() && s.now().Sub(row.RotatedAt) > refreshGrace) {
		return row, store.ErrNotFound
	}
	return row, nil
}

// GetClientByClientID is every client lookup zitadel makes.
func (s *storage) GetClientByClientID(ctx context.Context, id string) (op.Client, error) {
	c, err := s.clients.get(ctx, id)
	if err != nil {
		return nil, err
	}
	return c, nil
}

// AuthorizeClientIDSecret checks a registered client's secret (client_secret_basic or _post).
func (s *storage) AuthorizeClientIDSecret(ctx context.Context, id, secret string) error {
	c, err := s.clients.get(ctx, id)
	if err != nil {
		return err
	}
	if !c.secretMatches(secret) {
		return oidc.ErrInvalidClient().WithDescription("Client authentication failed.")
	}
	return nil
}

// DeleteAuthRequest keeps the code's row: it stays, marked used, so that the code presented
// again is recognized and ends its grant (FR-096). The purge removes it when it expires.
func (s *storage) DeleteAuthRequest(context.Context, string) error { return nil }

// Health is part of op.Storage; the relay has its own health check.
func (s *storage) Health(context.Context) error { return nil }

// errNotOffered answers the parts of op.Storage the relay doesn't offer: OpenID Connect (ID
// tokens, userinfo, signing keys), its own /authorize flow (the relay shows its own pages and
// stores the code itself, see Server.authorize), introspection, JWT profile and client
// assertions, and end-session. zitadel calls none of them for the endpoints the relay mounts.
func errNotOffered() *oidc.Error {
	return oidc.ErrRequestNotSupported().WithDescription("Not offered by this server.")
}

func (s *storage) CreateAuthRequest(context.Context, *oidc.AuthRequest, string) (op.AuthRequest, error) {
	return nil, errNotOffered()
}

func (s *storage) AuthRequestByID(context.Context, string) (op.AuthRequest, error) {
	return nil, errNotOffered()
}
func (s *storage) SaveAuthCode(context.Context, string, string) error     { return errNotOffered() }
func (s *storage) TerminateSession(context.Context, string, string) error { return errNotOffered() }
func (s *storage) SigningKey(context.Context) (op.SigningKey, error)      { return nil, errNotOffered() }

func (s *storage) SignatureAlgorithms(context.Context) ([]jose.SignatureAlgorithm, error) {
	return nil, errNotOffered()
}
func (s *storage) KeySet(context.Context) ([]op.Key, error) { return nil, errNotOffered() }
func (s *storage) SetUserinfoFromScopes(context.Context, *oidc.UserInfo, string, string, []string) error {
	return errNotOffered()
}

func (s *storage) SetUserinfoFromToken(context.Context, *oidc.UserInfo, string, string, string) error {
	return errNotOffered()
}

func (s *storage) SetIntrospectionFromToken(context.Context, *oidc.IntrospectionResponse, string, string, string) error {
	return errNotOffered()
}

func (s *storage) GetPrivateClaimsFromScopes(context.Context, string, string, []string) (map[string]any, error) {
	return nil, errNotOffered()
}

func (s *storage) GetKeyByIDAndClientID(context.Context, string, string) (*jose.JSONWebKey, error) {
	return nil, errNotOffered()
}

func (s *storage) ValidateJWTProfileScopes(context.Context, string, []string) ([]string, error) {
	return nil, errNotOffered()
}

// opaqueCrypto is zitadel's Crypto for the relay's opaque tokens (op.WithCrypto). zitadel makes
// a bearer access token by "encrypting" the token ID and subject; the relay's access token is
// its own ID (an HMAC token, stored by signature), so Encrypt returns the ID unchanged. Decrypt
// returns the token with an empty subject, so zitadel's revocation hands the token itself to
// RevokeToken and never tries to read it as a JWT.
type opaqueCrypto struct{}

func (opaqueCrypto) Encrypt(idAndSubject string) (string, error) {
	id, _, _ := strings.Cut(idAndSubject, ":")
	return id, nil
}

func (opaqueCrypto) Decrypt(token string) (string, error) { return token + ":", nil }

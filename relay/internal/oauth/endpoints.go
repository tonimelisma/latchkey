package oauth

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/modelcontextprotocol/go-sdk/auth"
	httphelper "github.com/zitadel/oidc/v3/pkg/http"
	"github.com/zitadel/oidc/v3/pkg/oidc"
	"github.com/zitadel/oidc/v3/pkg/op"

	"github.com/tonimelisma/latchkey/relay/internal/events"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// minStateLength is the least a client's state may be: a state is its defense against a code
// injected into its redirect, so a short one is refused (as the relay always has).
const minStateLength = 8

// authorizeRequest is a checked /authorize request.
type authorizeRequest struct {
	*oidc.AuthRequest
	client   *client
	redirect *url.URL
	granted  []string
}

// Two error codes zitadel has no constructor for: RFC 6749's unsupported_response_type, and
// invalid_state, which the relay has always answered for a missing or short state.
func unsupportedResponseType() *oidc.Error {
	e := oidc.ErrInvalidRequest().WithDescription("Only the response_type code is supported.")
	e.ErrorType = "unsupported_response_type"
	return e
}

func invalidState() *oidc.Error {
	e := oidc.ErrInvalidRequest().WithDescription("The state is missing or has fewer than 8 characters.")
	e.ErrorType = "invalid_state"
	return e
}

// checkAuthorize parses and checks an /authorize request with zitadel's parser and checks. An
// error with a nil request is shown in the browser, because the client or its redirect URI
// isn't trusted (FR-183); with a request, it goes back to the client's redirect URI.
func (s *Server) checkAuthorize(ctx context.Context, r *http.Request) (*authorizeRequest, error) {
	req, err := op.ParseAuthorizeRequest(r, s.op.Decoder())
	if err != nil {
		return nil, err
	}
	// First the client: the list of allowed client hosts is checked before anything is fetched.
	cl, err := s.clients.get(ctx, req.ClientID)
	if err != nil {
		return nil, s.clients.allowed.told(err)
	}
	// Exactly a registered redirect URI (a loopback one on any port, see clients.get).
	if err := op.ValidateAuthReqRedirectURI(cl, req.RedirectURI, req.ResponseType); err != nil {
		return nil, err
	}
	redirect, err := url.Parse(req.RedirectURI)
	if err != nil {
		return nil, oidc.ErrInvalidRequestRedirectURI().WithDescription("The redirect_uri is not valid.")
	}
	ar := &authorizeRequest{AuthRequest: req, client: cl, redirect: redirect}
	if req.ResponseType != oidc.ResponseTypeCode {
		return ar, unsupportedResponseType()
	}
	if len(req.State) < minStateLength {
		return ar, invalidState()
	}
	for _, sc := range req.Scopes {
		if !cl.IsScopeAllowed(sc) {
			return ar, oidc.ErrInvalidScope().WithDescription("The scope %q is not offered; ask for mcp and offline_access.", sc)
		}
	}
	// PKCE with S256 on every request (OAuth 2.1); plain is refused.
	if req.CodeChallenge == "" {
		return ar, oidc.ErrInvalidRequest().WithDescription("PKCE is required: send code_challenge and code_challenge_method S256.")
	}
	if req.CodeChallengeMethod != oidc.CodeChallengeMethodS256 {
		return ar, oidc.ErrInvalidRequest().WithDescription("Only the code_challenge_method S256 is supported.")
	}
	// RFC 8707: a resource indicator, if given, must name this relay's MCP endpoint.
	if res := r.Form.Get("resource"); res != "" && strings.TrimSuffix(res, "/") != s.resource {
		return ar, oidc.ErrInvalidRequest().WithDescription("Unknown resource.")
	}
	ar.granted = grantable(req.Scopes)
	return ar, nil
}

func (s *Server) authorize(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	ctx := withRequestedRedirect(r.Context(), r.Form.Get("redirect_uri"))
	ar, err := s.checkAuthorize(ctx, r)
	if err != nil {
		if ar == nil {
			// A client the list refuses is told why, in the browser: no redirect URI was
			// accepted, so the browser is sent nowhere (FR-183).
			s.authorizePageError(w, err)
			return
		}
		s.redirectError(w, ar, err)
		return
	}
	userID, ok := s.cfg.Auth.CurrentUser(r)
	if !ok {
		s.cfg.Auth.SignIn(w, r)
		return
	}
	// Consent is asked every time (FR-049a): only the Owner's Allow, posted from the consent page
	// with its CSRF token, issues a code. Nothing is remembered, so a program on the Owner's
	// computer posing as an approved client (a loopback redirect on any port) gets no code
	// without the Owner seeing the page (RFC 8252 §8.6).
	if r.Method != http.MethodPost {
		s.cfg.Auth.Consent(w, r, consentFor(ar.client, ar.redirect))
		return
	}
	if !s.cfg.Auth.ValidCSRF(r) {
		http.Error(w, "This form expired. Go back and try again.", http.StatusForbidden)
		return
	}
	if r.PostForm.Get("decision") != "allow" {
		s.cfg.Events.Record(ctx, store.Event{
			Kind: events.ClaudeRefused, UserID: userID, Detail: eventLabel(label(ar.client, ar.redirect)),
		})
		s.redirectError(w, ar, oidc.ErrAccessDenied().WithDescription("The Owner declined."))
		return
	}
	requestID := uuid.NewString()
	code, err := s.storage.saveCode(ctx, requestID, userID, ar.client, ar.Scopes, ar.granted, url.Values{
		"response_type": {string(ar.ResponseType)}, "client_id": {ar.ClientID}, "redirect_uri": {ar.RedirectURI},
		"scope": {strings.Join(ar.Scopes, " ")}, "state": {ar.State},
		"code_challenge": {ar.CodeChallenge}, "code_challenge_method": {string(ar.CodeChallengeMethod)},
	})
	if err != nil {
		s.cfg.Logger.Error("store authorization code", "err", err)
		s.redirectError(w, ar, oidc.ErrServerError())
		return
	}
	// The approval is recorded before its code leaves, so every token has a grant to be listed
	// and removed by (FR-190).
	if err := s.recordGrant(ctx, requestID, userID, ar.client, ar.redirect); err != nil {
		s.cfg.Logger.Error("record grant", "err", err)
		s.redirectError(w, ar, oidc.ErrServerError())
		return
	}
	s.cfg.Events.Record(ctx, store.Event{
		Kind: events.ClaudeApproved, UserID: userID, Detail: eventLabel(label(ar.client, ar.redirect)),
	})
	if s.cfg.OnAuthorized != nil {
		s.cfg.OnAuthorized(ctx, userID, label(ar.client, ar.redirect))
	}
	s.redirectBack(w, ar, url.Values{"code": {code}, "scope": {strings.Join(ar.granted, " ")}})
}

// redirectBack sends the browser back to the client with params, the client's state, and the
// relay as the issuer (RFC 9207, FR-097).
func (s *Server) redirectBack(w http.ResponseWriter, ar *authorizeRequest, params url.Values) {
	u := *ar.redirect
	q := u.Query()
	for k, v := range params {
		q[k] = v
	}
	if ar.State != "" {
		q.Set("state", ar.State)
	}
	q.Set("iss", s.issuer)
	u.RawQuery = q.Encode()
	w.Header().Set("Location", u.String())
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusSeeOther)
}

func (s *Server) redirectError(w http.ResponseWriter, ar *authorizeRequest, err error) {
	e := oidc.DefaultToServerError(err, "")
	params := url.Values{"error": {string(e.ErrorType)}}
	if e.Description != "" {
		params.Set("error_description", e.Description)
	}
	s.redirectBack(w, ar, params)
}

// authorizePageError shows an /authorize error in the browser, as JSON: invalid_client is 401,
// a server error 500, anything else 400.
func (s *Server) authorizePageError(w http.ResponseWriter, err error) {
	e := oidc.DefaultToServerError(err, "")
	if e.ErrorType == oidc.ServerError {
		s.cfg.Logger.Error("authorize", "err", err)
	}
	w.Header().Set("Cache-Control", "no-store")
	httphelper.MarshalJSONWithStatus(w, e, errorStatus(e))
}

func errorStatus(e *oidc.Error) int {
	switch e.ErrorType {
	case oidc.InvalidClient:
		return http.StatusUnauthorized
	case oidc.ServerError:
		return http.StatusInternalServerError
	}
	return http.StatusBadRequest
}

// grantable returns the requested scopes the relay grants; "mcp" is always granted.
func grantable(requested []string) []string {
	out := []string{"mcp"}
	if slices.Contains(requested, "offline_access") {
		out = append(out, "offline_access")
	}
	return out
}

// refuseClientAssertion refuses a request that authenticates its client with a signed JWT
// (private_key_jwt or client_secret_jwt, RFC 7523). The relay offers neither, and the
// assertion is never parsed: parsing attacker-chosen JWTs is where GHSA-mgcc-cww5-fp2q (a CPU
// denial of service in go-jose) was reachable before (plan D4).
func refuseClientAssertion(r *http.Request) error {
	if err := r.ParseForm(); err != nil {
		return oidc.ErrInvalidRequest().WithDescription("The request body is not a valid form.")
	}
	if r.Form.Has("client_assertion") || r.Form.Has("client_assertion_type") {
		return oidc.ErrInvalidClient().WithDescription("Client assertions (private_key_jwt, client_secret_jwt) are not supported.")
	}
	return nil
}

// token is POST /token: the authorization code and refresh token grants. zitadel parses the
// request, authenticates the client, checks PKCE, the redirect URI and the scopes; storage
// uses up the code or rotates the refresh token and writes the new tokens. The response is put
// together here rather than by zitadel's handler, which always adds an OpenID Connect ID token.
func (s *Server) token(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Pragma", "no-cache")
	var resp *oidc.AccessTokenResponse
	err := refuseClientAssertion(r)
	if err == nil {
		switch gt := r.PostForm.Get("grant_type"); gt {
		case string(oidc.GrantTypeCode):
			resp, err = s.codeExchange(ctx, r)
		case string(oidc.GrantTypeRefreshToken):
			resp, err = s.refreshExchange(ctx, r)
		case "":
			err = oidc.ErrInvalidRequest().WithDescription("grant_type is missing.")
		default:
			err = oidc.ErrUnsupportedGrantType().WithDescription("Only authorization_code and refresh_token are supported.")
		}
	}
	if err != nil {
		e := oidc.DefaultToServerError(s.clients.allowed.told(err), "")
		if e.ErrorType == oidc.ServerError {
			s.cfg.Logger.Error("token", "err", err)
		}
		httphelper.MarshalJSONWithStatus(w, e, errorStatus(e))
		return
	}
	httphelper.MarshalJSON(w, resp)
}

func (s *Server) codeExchange(ctx context.Context, r *http.Request) (*oidc.AccessTokenResponse, error) {
	tokenReq, err := op.ParseAccessTokenRequest(r, s.op.Decoder())
	if err != nil {
		return nil, err
	}
	if tokenReq.Code == "" {
		return nil, oidc.ErrInvalidRequest().WithDescription("code is missing.")
	}
	if tokenReq.CodeVerifier != "" && !validVerifier(tokenReq.CodeVerifier) {
		return nil, oidc.ErrInvalidGrant().WithDescription("The PKCE code_verifier must be 43 to 128 characters of A-Z, a-z, 0-9, and -._~.")
	}
	codeReq, cl, err := op.ValidateAccessTokenRequest(ctx, tokenReq, s.op)
	if err != nil {
		return nil, err
	}
	// Every code carries an S256 challenge (/authorize requires it), so zitadel has checked the
	// verifier; one without (which storage already refuses) is never exchanged.
	if ch := codeReq.GetCodeChallenge(); ch == nil || ch.Method != oidc.CodeChallengeMethodS256 {
		return nil, invalidGrant()
	}
	resp, err := s.tokenResponse(ctx, codeReq, cl, "")
	if err != nil {
		return nil, err
	}
	// A redeemed code is a new app with access: the Owner's Mac gets the new list (FR-192).
	s.grantsChanged(ctx, codeReq.GetSubject())
	return resp, nil
}

func (s *Server) refreshExchange(ctx context.Context, r *http.Request) (*oidc.AccessTokenResponse, error) {
	tokenReq, err := op.ParseRefreshTokenRequest(r, s.op.Decoder())
	if err != nil {
		return nil, err
	}
	refreshReq, cl, err := op.ValidateRefreshTokenRequest(ctx, tokenReq, s.op)
	if err != nil {
		return nil, err
	}
	return s.tokenResponse(ctx, refreshReq, cl, tokenReq.RefreshToken)
}

// tokenResponse issues the tokens through zitadel's CreateAccessToken, which asks storage for a
// refresh token too when offline_access was granted (or for a refresh).
func (s *Server) tokenResponse(ctx context.Context, req op.TokenRequest, cl op.Client, current string) (*oidc.AccessTokenResponse, error) {
	access, refresh, validity, err := op.CreateAccessToken(ctx, req, cl.AccessTokenType(), s.op, cl, current)
	if err != nil {
		return nil, err
	}
	return &oidc.AccessTokenResponse{
		AccessToken: access, RefreshToken: refresh, TokenType: "bearer",
		ExpiresIn: uint64(max(validity.Round(time.Second), 0) / time.Second), Scope: req.GetScopes(),
	}, nil
}

// validVerifier is RFC 7636 §4.1: 43 to 128 unreserved characters.
func validVerifier(v string) bool {
	if len(v) < 43 || len(v) > 128 {
		return false
	}
	return !strings.ContainsFunc(v, func(c rune) bool {
		return (c < 'A' || c > 'Z') && (c < 'a' || c > 'z') && (c < '0' || c > '9') && !strings.ContainsRune("-._~", c)
	})
}

// revoke is POST /revoke (RFC 7009), zitadel's handler: it authenticates the client, and
// storage revokes the token's grant.
func (s *Server) revoke(w http.ResponseWriter, r *http.Request) {
	if err := refuseClientAssertion(r); err != nil {
		op.RevocationRequestError(w, r, err)
		return
	}
	op.Revoke(w, r, s.op)
}

// verify maps an access token to its Owner for the MCP SDK. Refresh tokens and codes are not
// access tokens.
func (s *Server) verify(ctx context.Context, token string, _ *http.Request) (*auth.TokenInfo, error) {
	row, err := s.storage.activeToken(ctx, token)
	if err != nil {
		if !errors.Is(err, store.ErrNotFound) {
			events.Note(ctx, "token check failed")
			return nil, err
		}
		if _, ok := s.storage.tokens.signature(prefixRefresh, token); ok {
			events.Note(ctx, "token rejected: not an access token")
		} else {
			events.Note(ctx, "token rejected: unknown, expired, or revoked")
		}
		return nil, auth.ErrInvalidToken
	}
	if row.UserID == "" {
		return nil, auth.ErrInvalidToken
	}
	// A suspended account's tokens are deleted with the suspension; this also covers one that
	// slipped in beside it (FR-196).
	if u, err := s.cfg.Store.User(ctx, row.UserID); err != nil || !u.SuspendedAt.IsZero() {
		events.Note(ctx, "token rejected: account suspended or gone")
		return nil, auth.ErrInvalidToken
	}
	events.NoteUser(ctx, row.UserID)
	info := &auth.TokenInfo{
		UserID:     row.UserID,
		Scopes:     strings.Fields(row.GrantedScopes),
		Expiration: row.ExpiresAt,
	}
	if grantID := s.used(ctx, row.RequestID); grantID != "" {
		info.Extra = map[string]any{GrantExtra: grantID}
	}
	return info, nil
}

package store

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// UserByEmail finds a user by exact (already normalized) email.
func (s *Store) UserByEmail(ctx context.Context, email string) (User, error) {
	var id string
	err := s.db.QueryRowContext(ctx, `SELECT id FROM users WHERE email = ? AND deleted_at IS NULL`, email).Scan(&id)
	if err != nil {
		return User{}, mapErr(err)
	}
	return s.User(ctx, id)
}

// AnyVerifiedUser reports whether any account has been created (its email verified), so a setup
// code no longer opens sign-up (spec 009 FR-907).
func (s *Store) AnyVerifiedUser(ctx context.Context) (bool, error) {
	var any bool
	err := s.db.QueryRowContext(ctx,
		`SELECT EXISTS(SELECT 1 FROM users WHERE email_verified_at IS NOT NULL AND deleted_at IS NULL)`).Scan(&any)
	return any, err
}

// VerifyEmail marks the user's email verified, keeping the first verification time.
func (s *Store) VerifyEmail(ctx context.Context, userID string, at time.Time) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE users SET email_verified_at = COALESCE(email_verified_at, ?) WHERE id = ?`, toMS(at), userID)
	if err != nil {
		return err
	}
	return requireOneRow(res)
}

// DeleteUser hard-deletes the user and, through foreign keys, everything about them (FR-045).
func (s *Store) DeleteUser(ctx context.Context, userID string) error {
	res, err := s.db.ExecContext(ctx, `DELETE FROM users WHERE id = ?`, userID)
	if err != nil {
		return err
	}
	return requireOneRow(res)
}

// PurgeUnverifiedUsers deletes sign-ups never verified and created before the cutoff.
func (s *Store) PurgeUnverifiedUsers(ctx context.Context, before time.Time) (int64, error) {
	res, err := s.db.ExecContext(ctx,
		`DELETE FROM users WHERE email_verified_at IS NULL AND created_at < ?`, before.UnixMilli())
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// Passkey is a stored WebAuthn credential.
type Passkey struct {
	UserID         string
	CredentialID   []byte
	CredentialJSON []byte
	CreatedAt      time.Time
	LastUsedAt     time.Time
}

// AddPasskey stores a new credential. A known credential ID is ErrConflict.
func (s *Store) AddPasskey(ctx context.Context, userID string, credID, credJSON []byte, at time.Time) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO passkeys (user_id, credential_id, credential_json, created_at) VALUES (?, ?, ?, ?)`,
		userID, credID, string(credJSON), toMS(at))
	return mapErr(err)
}

const passkeyColumns = //nolint:gosec // column names, not credentials
`user_id, credential_id, credential_json, created_at, last_used_at`

func scanPasskey(scan func(...any) error) (Passkey, error) {
	var p Passkey
	var credJSON string
	var created, used sql.NullInt64
	if err := scan(&p.UserID, &p.CredentialID, &credJSON, &created, &used); err != nil {
		return Passkey{}, mapErr(err)
	}
	p.CredentialJSON, p.CreatedAt, p.LastUsedAt = []byte(credJSON), fromMS(created), fromMS(used)
	return p, nil
}

// Passkeys lists the user's credentials, oldest first.
func (s *Store) Passkeys(ctx context.Context, userID string) ([]Passkey, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT `+passkeyColumns+` FROM passkeys WHERE user_id = ? ORDER BY id`, userID)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var out []Passkey
	for rows.Next() {
		p, err := scanPasskey(rows.Scan)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// PasskeyByCredentialID finds a credential.
func (s *Store) PasskeyByCredentialID(ctx context.Context, credID []byte) (Passkey, error) {
	return scanPasskey(s.db.QueryRowContext(ctx,
		`SELECT `+passkeyColumns+` FROM passkeys WHERE credential_id = ?`, credID).Scan)
}

// UpdatePasskey saves a credential after use (new sign count, flags).
func (s *Store) UpdatePasskey(ctx context.Context, credID, credJSON []byte, usedAt time.Time) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE passkeys SET credential_json = ?, last_used_at = ? WHERE credential_id = ?`,
		string(credJSON), toMS(usedAt), credID)
	if err != nil {
		return err
	}
	return requireOneRow(res)
}

// DeletePasskeysExcept removes all of the user's credentials but one (FR-047).
func (s *Store) DeletePasskeysExcept(ctx context.Context, userID string, keep []byte) (int64, error) {
	res, err := s.db.ExecContext(ctx,
		`DELETE FROM passkeys WHERE user_id = ? AND credential_id != ?`, userID, keep)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// Email token purposes.
const (
	PurposeVerify  = "verify"
	PurposeRecover = "recover"
)

// CreateEmailToken stores a hashed single-use link token.
func (s *Store) CreateEmailToken(ctx context.Context, hash []byte, userID, purpose string, expires time.Time) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO email_tokens (token_hash, user_id, purpose, expires_at) VALUES (?, ?, ?, ?)`,
		hash, userID, purpose, toMS(expires))
	return mapErr(err)
}

// PeekEmailToken returns the token's user if it is unused and unexpired, without using it.
// Opening a link only peeks; mail scanners that prefetch links cannot consume them.
func (s *Store) PeekEmailToken(ctx context.Context, hash []byte, purpose string, now time.Time) (string, error) {
	var userID string
	err := s.db.QueryRowContext(ctx, `
		SELECT user_id FROM email_tokens
		WHERE token_hash = ? AND purpose = ? AND used_at IS NULL AND expires_at > ?`,
		hash, purpose, now.UnixMilli()).Scan(&userID)
	return userID, mapErr(err)
}

// UseEmailToken consumes the token and returns its user.
func (s *Store) UseEmailToken(ctx context.Context, hash []byte, purpose string, now time.Time) (string, error) {
	var userID string
	err := s.db.QueryRowContext(ctx, `
		UPDATE email_tokens SET used_at = ?
		WHERE token_hash = ? AND purpose = ? AND used_at IS NULL AND expires_at > ?
		RETURNING user_id`,
		toMS(now), hash, purpose, now.UnixMilli()).Scan(&userID)
	return userID, mapErr(err)
}

// RecoveriesSince returns when the user's recovery links were used after the given time.
func (s *Store) RecoveriesSince(ctx context.Context, userID string, since time.Time) ([]time.Time, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT used_at FROM email_tokens
		WHERE user_id = ? AND purpose = 'recover' AND used_at > ? ORDER BY used_at`,
		userID, since.UnixMilli())
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var out []time.Time
	for rows.Next() {
		var at sql.NullInt64
		if err := rows.Scan(&at); err != nil {
			return nil, err
		}
		out = append(out, fromMS(at))
	}
	return out, rows.Err()
}

// Session is a signed-in browser.
type Session struct {
	UserID    string
	ExpiresAt time.Time
	ReauthAt  time.Time
}

// CreateSession stores a web session by the hash of its cookie value.
func (s *Store) CreateSession(ctx context.Context, hash []byte, userID string, created, expires time.Time) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO web_sessions (id_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)`,
		hash, userID, toMS(created), toMS(expires))
	return mapErr(err)
}

// Session returns an unexpired session of an account that isn't suspended: a suspension ends
// every browser sign-in at once, also one made a moment after it (FR-196).
func (s *Store) Session(ctx context.Context, hash []byte, now time.Time) (Session, error) {
	var sess Session
	var expires, reauth sql.NullInt64
	err := s.db.QueryRowContext(ctx, `
		SELECT w.user_id, w.expires_at, w.reauth_at FROM web_sessions w JOIN users u ON u.id = w.user_id
		WHERE w.id_hash = ? AND w.expires_at > ? AND u.suspended_at IS NULL`,
		hash, now.UnixMilli()).Scan(&sess.UserID, &expires, &reauth)
	if err != nil {
		return Session{}, mapErr(err)
	}
	sess.ExpiresAt, sess.ReauthAt = fromMS(expires), fromMS(reauth)
	return sess, nil
}

// SetSessionReauth records a fresh passkey check.
func (s *Store) SetSessionReauth(ctx context.Context, hash []byte, at time.Time) error {
	res, err := s.db.ExecContext(ctx, `UPDATE web_sessions SET reauth_at = ? WHERE id_hash = ?`, toMS(at), hash)
	if err != nil {
		return err
	}
	return requireOneRow(res)
}

// DeleteSession signs a browser out.
func (s *Store) DeleteSession(ctx context.Context, hash []byte) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM web_sessions WHERE id_hash = ?`, hash)
	return err
}

// DeleteUserSessions signs the user out everywhere.
func (s *Store) DeleteUserSessions(ctx context.Context, userID string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM web_sessions WHERE user_id = ?`, userID)
	return err
}

// CreatePairingCode stores a hashed single-use pairing code.
func (s *Store) CreatePairingCode(ctx context.Context, hash []byte, userID string, expires time.Time) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO pairing_codes (code_hash, user_id, expires_at) VALUES (?, ?, ?)`, hash, userID, toMS(expires))
	return mapErr(err)
}

// PeekPairingCode returns the code's user if it is unused and unexpired, without using it.
// The Mac app asks whose code a pairing link carries before the Owner confirms (FR-054).
func (s *Store) PeekPairingCode(ctx context.Context, hash []byte, now time.Time) (string, error) {
	var userID string
	err := s.db.QueryRowContext(ctx, `
		SELECT user_id FROM pairing_codes
		WHERE code_hash = ? AND used_at IS NULL AND expires_at > ?`, hash, now.UnixMilli()).Scan(&userID)
	return userID, mapErr(err)
}

// UsePairingCode consumes the code and returns its user.
func (s *Store) UsePairingCode(ctx context.Context, hash []byte, now time.Time) (string, error) {
	var userID string
	err := s.db.QueryRowContext(ctx, `
		UPDATE pairing_codes SET used_at = ?
		WHERE code_hash = ? AND used_at IS NULL AND expires_at > ?
		RETURNING user_id`, toMS(now), hash, now.UnixMilli()).Scan(&userID)
	return userID, mapErr(err)
}

// OAuthClient is a registered (DCR) or fetched (CIMD) client.
type OAuthClient struct {
	ID           string
	Kind         string // "dcr" or "cimd"
	MetadataJSON []byte
	SecretHash   []byte
	CreatedAt    time.Time
	FetchedAt    time.Time
}

// PutOAuthClient inserts or replaces a client.
func (s *Store) PutOAuthClient(ctx context.Context, c OAuthClient) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO oauth_clients (id, kind, metadata_json, secret_hash, created_at, fetched_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, metadata_json = excluded.metadata_json,
			secret_hash = excluded.secret_hash, fetched_at = excluded.fetched_at`,
		c.ID, c.Kind, string(c.MetadataJSON), c.SecretHash, toMS(c.CreatedAt), toMS(c.FetchedAt))
	return mapErr(err)
}

// MaxClientDocumentAge is the longest a cached client metadata document counts as fresh; one
// fetched longer ago, with no code or token of its client left, is purged.
const MaxClientDocumentAge = 24 * time.Hour

// PutCachedClient stores a fetched client metadata document and keeps the cache bounded: of the
// cached documents beyond the newest max, those no code or token refers to are deleted. Anyone
// can make the relay fetch a document by naming its URL, so without this the table could be
// filled; documents of clients that hold a grant are never dropped.
func (s *Store) PutCachedClient(ctx context.Context, c OAuthClient, max int) error {
	if err := s.PutOAuthClient(ctx, c); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, `
		DELETE FROM oauth_clients
		WHERE kind = 'cimd' AND id <> ?
			AND id IN (SELECT id FROM oauth_clients WHERE kind = 'cimd'
				ORDER BY COALESCE(fetched_at, created_at) DESC, id LIMIT -1 OFFSET ?)
			AND NOT EXISTS (SELECT 1 FROM oauth_requests r WHERE r.client_id = oauth_clients.id)`, c.ID, max)
	return err
}

// OAuthClient returns a client.
func (s *Store) OAuthClient(ctx context.Context, id string) (OAuthClient, error) {
	var c OAuthClient
	var meta string
	var created, fetched sql.NullInt64
	err := s.db.QueryRowContext(ctx,
		`SELECT id, kind, metadata_json, secret_hash, created_at, fetched_at FROM oauth_clients WHERE id = ?`, id,
	).Scan(&c.ID, &c.Kind, &meta, &c.SecretHash, &created, &fetched)
	if err != nil {
		return OAuthClient{}, mapErr(err)
	}
	c.MetadataJSON, c.CreatedAt, c.FetchedAt = []byte(meta), fromMS(created), fromMS(fetched)
	return c, nil
}

// OAuth request kinds.
const (
	KindCode    = "code"
	KindPKCE    = "pkce"
	KindAccess  = "access"
	KindRefresh = "refresh"
)

// OAuthRequest is a fosite request stored under a token signature.
type OAuthRequest struct {
	Signature     string
	Kind          string
	RequestID     string
	ClientID      string
	UserID        string
	RequestedAt   time.Time
	Scopes        string
	GrantedScopes string
	Form          string
	SessionJSON   []byte
	ExpiresAt     time.Time
	UsedAt        time.Time
	RotatedAt     time.Time
	RevokedAt     time.Time
}

const oauthRequestColumns = `signature, kind, request_id, client_id, user_id, requested_at, scopes,
	granted_scopes, form, session_json, expires_at`

func (r OAuthRequest) values() []any {
	return []any{
		r.Signature, r.Kind, r.RequestID, r.ClientID, nullString(r.UserID), toMS(r.RequestedAt), r.Scopes,
		r.GrantedScopes, r.Form, string(r.SessionJSON), toMS(r.ExpiresAt),
	}
}

// PutOAuthRequest stores a request.
func (s *Store) PutOAuthRequest(ctx context.Context, r OAuthRequest) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO oauth_requests (`+oauthRequestColumns+`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, r.values()...)
	return mapErr(err)
}

// PutOAuthToken stores an access or refresh token only while its grant is live: the
// authorization code or a refresh token of the same request ID and user still exists, and no
// token of that grant was revoked (revocation is final for a grant). The check and the insert
// are one statement, so a token issued in the middle of "Remove Claude's access" (which deletes
// the rows) or of a client's /revoke or reuse detection (which mark them revoked) is never
// written; the caller gets ErrNotFound (security scan).
func (s *Store) PutOAuthToken(ctx context.Context, r OAuthRequest) error {
	if r.Kind != KindAccess && r.Kind != KindRefresh {
		return fmt.Errorf("PutOAuthToken: kind %q is not a token", r.Kind)
	}
	res, err := s.db.ExecContext(ctx, `
		INSERT INTO oauth_requests (`+oauthRequestColumns+`)
		SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
		WHERE EXISTS (SELECT 1 FROM oauth_requests
				WHERE request_id = ? AND user_id = ? AND kind IN ('code', 'refresh'))
			AND NOT EXISTS (SELECT 1 FROM oauth_requests
				WHERE request_id = ? AND revoked_at IS NOT NULL)`,
		append(r.values(), r.RequestID, r.UserID, r.RequestID)...)
	if err != nil {
		return mapErr(err)
	}
	return requireOneRow(res)
}

// OAuthRequest returns a stored request, whatever its state.
func (s *Store) OAuthRequest(ctx context.Context, kind, signature string) (OAuthRequest, error) {
	var r OAuthRequest
	var user sql.NullString
	var session string
	var requested, expires, used, rotated, revoked sql.NullInt64
	err := s.db.QueryRowContext(ctx, `
		SELECT signature, kind, request_id, client_id, user_id, requested_at, scopes, granted_scopes, form,
			session_json, expires_at, used_at, rotated_at, revoked_at
		FROM oauth_requests WHERE kind = ? AND signature = ?`, kind, signature,
	).Scan(&r.Signature, &r.Kind, &r.RequestID, &r.ClientID, &user, &requested, &r.Scopes, &r.GrantedScopes,
		&r.Form, &session, &expires, &used, &rotated, &revoked)
	if err != nil {
		return OAuthRequest{}, mapErr(err)
	}
	r.UserID, r.SessionJSON = user.String, []byte(session)
	r.RequestedAt, r.ExpiresAt = fromMS(requested), fromMS(expires)
	r.UsedAt, r.RotatedAt, r.RevokedAt = fromMS(used), fromMS(rotated), fromMS(revoked)
	return r, nil
}

func (s *Store) updateOAuthRequest(ctx context.Context, query string, args ...any) error {
	res, err := s.db.ExecContext(ctx, query, args...)
	if err != nil {
		return err
	}
	return requireOneRow(res)
}

// MarkOAuthRequestUsed records that an authorization code was redeemed. Only the first caller
// succeeds: a code that is already used (or doesn't exist) is ErrNotFound, so of two exchanges
// racing on one code exactly one gets past this statement.
func (s *Store) MarkOAuthRequestUsed(ctx context.Context, kind, signature string, at time.Time) error {
	return s.updateOAuthRequest(ctx,
		`UPDATE oauth_requests SET used_at = ? WHERE kind = ? AND signature = ? AND used_at IS NULL`, toMS(at), kind, signature)
}

// RevokeGrant marks every row of a grant revoked: its tokens stop working, and PutOAuthToken
// writes no more for it.
func (s *Store) RevokeGrant(ctx context.Context, requestID string, at time.Time) error {
	_, err := s.db.ExecContext(ctx,
		`UPDATE oauth_requests SET revoked_at = COALESCE(revoked_at, ?) WHERE request_id = ?`, toMS(at), requestID)
	return err
}

// RotateOAuthRequest records that a refresh token was exchanged; the first rotation time counts.
func (s *Store) RotateOAuthRequest(ctx context.Context, kind, signature string, at time.Time) error {
	return s.updateOAuthRequest(ctx,
		`UPDATE oauth_requests SET rotated_at = COALESCE(rotated_at, ?) WHERE kind = ? AND signature = ?`, toMS(at), kind, signature)
}

// RevokeOAuthRequests revokes every token of a kind issued for one grant.
func (s *Store) RevokeOAuthRequests(ctx context.Context, kind, requestID string, at time.Time) error {
	_, err := s.db.ExecContext(ctx,
		`UPDATE oauth_requests SET revoked_at = COALESCE(revoked_at, ?) WHERE kind = ? AND request_id = ?`, toMS(at), kind, requestID)
	return err
}

// DeleteOAuthRequest removes a stored request.
func (s *Store) DeleteOAuthRequest(ctx context.Context, kind, signature string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM oauth_requests WHERE kind = ? AND signature = ?`, kind, signature)
	return err
}

// DeleteUserOAuth removes all of the user's codes and tokens (FR-044). Tokens are written only
// while their grant's rows exist (PutOAuthToken), so none can be issued for the user after this.
func (s *Store) DeleteUserOAuth(ctx context.Context, userID string) error {
	if _, err := s.db.ExecContext(ctx, `DELETE FROM oauth_requests WHERE user_id = ?`, userID); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM oauth_grants WHERE user_id = ?`, userID)
	return err
}

// PurgeExpired deletes expired sessions, links, pairing codes, OAuth requests, unused
// registered clients, and unused cached client documents. It returns the grants it removed
// because none of their codes or tokens was left, for the event record (FR-631).
func (s *Store) PurgeExpired(ctx context.Context, now time.Time) ([]Grant, error) {
	ms := now.UnixMilli()
	var errs []error
	for _, q := range []string{
		`DELETE FROM web_sessions WHERE expires_at <= ?`,
		`DELETE FROM email_tokens WHERE expires_at <= ? AND purpose = 'verify'`,
		`DELETE FROM pairing_codes WHERE expires_at <= ?`,
		`DELETE FROM oauth_requests WHERE expires_at <= ?`,
	} {
		if _, err := s.db.ExecContext(ctx, q, ms); err != nil {
			errs = append(errs, err)
		}
	}
	// A grant none of whose codes or tokens is left (expired and deleted above, or removed).
	ended, err := s.purgeEndedGrants(ctx)
	if err != nil {
		errs = append(errs, err)
	}
	// Dynamically registered clients older than a week with no live code or token are never
	// coming back; without this, anyone could fill the table through /register.
	if _, err := s.db.ExecContext(ctx, `
		DELETE FROM oauth_clients WHERE kind = 'dcr' AND created_at <= ?
			AND NOT EXISTS (SELECT 1 FROM oauth_requests r WHERE r.client_id = oauth_clients.id)`,
		now.Add(-7*24*time.Hour).UnixMilli()); err != nil {
		errs = append(errs, err)
	}
	// Cached client metadata documents that are past any freshness and belong to no live code
	// or token: fetched again if the client ever returns.
	if _, err := s.db.ExecContext(ctx, `
		DELETE FROM oauth_clients WHERE kind = 'cimd' AND COALESCE(fetched_at, created_at) <= ?
			AND NOT EXISTS (SELECT 1 FROM oauth_requests r WHERE r.client_id = oauth_clients.id)`,
		now.Add(-MaxClientDocumentAge).UnixMilli()); err != nil {
		errs = append(errs, err)
	}
	// Used recovery links are kept for 30 days so a Mac that was offline still hears of them.
	if _, err := s.db.ExecContext(ctx,
		`DELETE FROM email_tokens WHERE purpose = 'recover' AND expires_at <= ? AND (used_at IS NULL OR used_at <= ?)`,
		ms, now.Add(-30*24*time.Hour).UnixMilli()); err != nil {
		errs = append(errs, err)
	}
	return ended, errors.Join(errs...)
}

func (s *Store) purgeEndedGrants(ctx context.Context) ([]Grant, error) {
	rows, err := s.db.QueryContext(ctx, `
		DELETE FROM oauth_grants WHERE NOT EXISTS
			(SELECT 1 FROM oauth_requests r WHERE r.request_id = oauth_grants.request_id)
		RETURNING `+grantColumns)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var out []Grant
	for rows.Next() {
		g, err := scanGrant(rows.Scan)
		if err != nil {
			return out, err
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

// MaxCodeAttempts is how many wrong codes end a code (FR-042).
const MaxCodeAttempts = 5

// MaxWrongCodesPerDay is how many wrong codes for one address, within a day of the first, refuse
// every emailed code until that day is over (FR-042a).
const MaxWrongCodesPerDay = 20

const wrongCodesWindow = 24 * time.Hour

// ErrCodesLocked means too many wrong codes were entered for the address today (FR-042a).
var ErrCodesLocked = errors.New("too many wrong codes today")

// wrongCodesLocked reads the user's count of wrong codes within the current day.
func wrongCodesLocked(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}, userID string, now time.Time,
) (bool, error) {
	var n int
	var since sql.NullInt64
	err := q.QueryRowContext(ctx, `SELECT wrong_codes, wrong_codes_since FROM users WHERE id = ?`, userID).Scan(&n, &since)
	if err != nil {
		return false, mapErr(err)
	}
	return since.Valid && now.Before(fromMS(since).Add(wrongCodesWindow)) && n >= MaxWrongCodesPerDay, nil
}

// EmailCodesLocked reports whether emailed codes are refused for the user right now (FR-042a).
func (s *Store) EmailCodesLocked(ctx context.Context, userID string, now time.Time) bool {
	locked, err := wrongCodesLocked(ctx, s.db, userID, now)
	return err == nil && locked
}

// ErrWrongCode means the code did not match; attempts remain.
var ErrWrongCode = errors.New("wrong code")

// CreateEmailCode stores a new code for the user and purpose, replacing any earlier unused one.
func (s *Store) CreateEmailCode(ctx context.Context, userID, purpose string, codeHash []byte, expires time.Time) error {
	if _, err := s.db.ExecContext(ctx,
		`DELETE FROM email_tokens WHERE user_id = ? AND purpose = ? AND used_at IS NULL`, userID, purpose); err != nil {
		return err
	}
	return s.CreateEmailToken(ctx, codeHash, userID, purpose, expires)
}

// CheckEmailCode uses the user's current code if codeHash matches. A wrong code counts an attempt
// on the code and a wrong code for the day (ErrWrongCode); an expired code, a used one, or one
// with too many attempts is ErrNotFound; after MaxWrongCodesPerDay wrong codes within a day,
// every code is ErrCodesLocked until the day is over. The check and the count are one
// transaction, so concurrent guesses can't get past either limit.
func (s *Store) CheckEmailCode(ctx context.Context, userID, purpose string, codeHash []byte, now time.Time) error {
	var result error
	err := s.immediate(ctx, func(conn *sql.Conn) error {
		locked, err := wrongCodesLocked(ctx, conn, userID, now)
		if err != nil {
			return err
		}
		if locked {
			result = ErrCodesLocked
			return nil
		}
		var stored []byte
		var attempts int
		err = conn.QueryRowContext(ctx, `
			SELECT token_hash, attempts FROM email_tokens
			WHERE user_id = ? AND purpose = ? AND used_at IS NULL AND expires_at > ?
			ORDER BY expires_at DESC LIMIT 1`, userID, purpose, now.UnixMilli()).Scan(&stored, &attempts)
		if errors.Is(err, sql.ErrNoRows) || (err == nil && attempts >= MaxCodeAttempts) {
			result = ErrNotFound
			return nil
		}
		if err != nil {
			return err
		}
		if subtle.ConstantTimeCompare(stored, codeHash) == 1 {
			_, err = conn.ExecContext(ctx, `UPDATE email_tokens SET used_at = ? WHERE token_hash = ?`, toMS(now), stored)
			return err
		}
		result = ErrWrongCode
		if _, err := conn.ExecContext(ctx, `UPDATE email_tokens SET attempts = attempts + 1 WHERE token_hash = ?`, stored); err != nil {
			return err
		}
		// A new day starts with the first wrong code after the last day ended.
		_, err = conn.ExecContext(ctx, `
			UPDATE users SET
				wrong_codes = CASE WHEN wrong_codes_since IS NULL OR wrong_codes_since <= ? THEN 1 ELSE wrong_codes + 1 END,
				wrong_codes_since = CASE WHEN wrong_codes_since IS NULL OR wrong_codes_since <= ? THEN ? ELSE wrong_codes_since END
			WHERE id = ?`,
			now.Add(-wrongCodesWindow).UnixMilli(), now.Add(-wrongCodesWindow).UnixMilli(), toMS(now), userID)
		return err
	})
	if err != nil {
		return err
	}
	return result
}

// ClientAuthorization is one time a Claude client was given access.
type ClientAuthorization struct {
	ID         int64
	ClientName string
	At         time.Time
}

// AddClientAuthorization records a grant; notified says the Mac was already told.
func (s *Store) AddClientAuthorization(ctx context.Context, userID, clientName string, at time.Time, notified bool) error {
	var n any
	if notified {
		n = toMS(at)
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO client_authorizations (user_id, client_name, at, notified_at) VALUES (?, ?, ?, ?)`,
		userID, clientName, toMS(at), n)
	return mapErr(err)
}

// TakeClientAuthorizations returns grants since `since` the Mac hasn't been told about, and marks
// them told.
func (s *Store) TakeClientAuthorizations(ctx context.Context, userID string, since, now time.Time) ([]ClientAuthorization, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, client_name, at FROM client_authorizations
		WHERE user_id = ? AND notified_at IS NULL AND at >= ? ORDER BY at`, userID, toMS(since))
	if err != nil {
		return nil, err
	}
	var out []ClientAuthorization
	for rows.Next() {
		var a ClientAuthorization
		var at sql.NullInt64
		if err := rows.Scan(&a.ID, &a.ClientName, &at); err != nil {
			_ = rows.Close()
			return nil, err
		}
		a.At = fromMS(at)
		out = append(out, a)
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	if _, err := s.db.ExecContext(ctx,
		`UPDATE client_authorizations SET notified_at = ? WHERE user_id = ? AND notified_at IS NULL AND at >= ?`,
		toMS(now), userID, toMS(since)); err != nil {
		return nil, err
	}
	return out, nil
}

// PurgeClientAuthorizations deletes grants recorded before `before`.
func (s *Store) PurgeClientAuthorizations(ctx context.Context, before time.Time) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM client_authorizations WHERE at < ?`, toMS(before))
	return err
}

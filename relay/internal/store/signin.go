package store

import (
	"context"
	"database/sql"
	"errors"
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

// Session returns an unexpired session.
func (s *Store) Session(ctx context.Context, hash []byte, now time.Time) (Session, error) {
	var sess Session
	var expires, reauth sql.NullInt64
	err := s.db.QueryRowContext(ctx,
		`SELECT user_id, expires_at, reauth_at FROM web_sessions WHERE id_hash = ? AND expires_at > ?`,
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

// PutOAuthRequest stores a request.
func (s *Store) PutOAuthRequest(ctx context.Context, r OAuthRequest) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO oauth_requests (signature, kind, request_id, client_id, user_id, requested_at, scopes,
			granted_scopes, form, session_json, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		r.Signature, r.Kind, r.RequestID, r.ClientID, nullString(r.UserID), toMS(r.RequestedAt), r.Scopes,
		r.GrantedScopes, r.Form, string(r.SessionJSON), toMS(r.ExpiresAt))
	return mapErr(err)
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

// MarkOAuthRequestUsed records that an authorization code was redeemed.
func (s *Store) MarkOAuthRequestUsed(ctx context.Context, kind, signature string, at time.Time) error {
	return s.updateOAuthRequest(ctx,
		`UPDATE oauth_requests SET used_at = COALESCE(used_at, ?) WHERE kind = ? AND signature = ?`, toMS(at), kind, signature)
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

// DeleteUserOAuth removes all of the user's tokens and remembered approvals (FR-044).
func (s *Store) DeleteUserOAuth(ctx context.Context, userID string) error {
	if _, err := s.db.ExecContext(ctx, `DELETE FROM oauth_requests WHERE user_id = ?`, userID); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM oauth_consents WHERE user_id = ?`, userID)
	return err
}

// Consent returns the scopes the user approved for a client.
func (s *Store) Consent(ctx context.Context, userID, clientID string) (string, error) {
	var scopes string
	err := s.db.QueryRowContext(ctx,
		`SELECT scopes FROM oauth_consents WHERE user_id = ? AND client_id = ?`, userID, clientID).Scan(&scopes)
	return scopes, mapErr(err)
}

// PutConsent remembers an approval (FR-049).
func (s *Store) PutConsent(ctx context.Context, userID, clientID, scopes string, at time.Time) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO oauth_consents (user_id, client_id, scopes, created_at) VALUES (?, ?, ?, ?)
		ON CONFLICT (user_id, client_id) DO UPDATE SET scopes = excluded.scopes, created_at = excluded.created_at`,
		userID, clientID, scopes, toMS(at))
	return mapErr(err)
}

// PurgeExpired deletes expired sessions, links, pairing codes, and OAuth requests.
func (s *Store) PurgeExpired(ctx context.Context, now time.Time) error {
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
	// Used recovery links are kept for 30 days so a Mac that was offline still hears of them.
	if _, err := s.db.ExecContext(ctx,
		`DELETE FROM email_tokens WHERE purpose = 'recover' AND expires_at <= ? AND (used_at IS NULL OR used_at <= ?)`,
		ms, now.Add(-30*24*time.Hour).UnixMilli()); err != nil {
		errs = append(errs, err)
	}
	return errors.Join(errs...)
}

// KeyOrCreate returns a server key, creating it with gen the first time.
func (s *Store) KeyOrCreate(ctx context.Context, name string, gen func() ([]byte, error)) ([]byte, error) {
	var v []byte
	err := s.db.QueryRowContext(ctx, `SELECT value FROM relay_keys WHERE name = ?`, name).Scan(&v)
	if err == nil {
		return v, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	v, err = gen()
	if err != nil {
		return nil, err
	}
	if _, err := s.db.ExecContext(ctx, `INSERT OR IGNORE INTO relay_keys (name, value) VALUES (?, ?)`, name, v); err != nil {
		return nil, err
	}
	err = s.db.QueryRowContext(ctx, `SELECT value FROM relay_keys WHERE name = ?`, name).Scan(&v)
	return v, err
}

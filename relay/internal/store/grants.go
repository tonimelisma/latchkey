package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// Grant is one approval the Owner gave on the Allow page (FR-190): the codes and tokens that
// share RequestID. ID is its public handle, shown to the Mac app and on the account page; the
// label fields are what the consent page showed (empty for a grant from before they were kept).
type Grant struct {
	RequestID  string
	ID         string
	UserID     string
	ClientID   string
	ClientName string
	ClientHost string
	Redirect   string
	ApprovedAt time.Time
	LastUsedAt time.Time
}

// NewGrantID returns a fresh public ID for a grant: 16 random bytes, unrelated to its tokens.
func NewGrantID() string { return newID("grt_") }

// AddGrant records an approval. It is written when the Owner allows the app, before the code
// leaves the relay.
func (s *Store) AddGrant(ctx context.Context, g Grant) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO oauth_grants (request_id, id, user_id, client_id, client_name, client_host, redirect, approved_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		g.RequestID, g.ID, g.UserID, g.ClientID, g.ClientName, g.ClientHost, g.Redirect, toMS(g.ApprovedAt))
	return mapErr(err)
}

const grantColumns = `request_id, id, user_id, client_id, client_name, client_host, redirect, approved_at, last_used_at`

// A grant is live while it holds an unrevoked, unexpired access or refresh token. This is what
// "has access" means everywhere (FR-049a: nothing else about an approval is kept).
const grantLive = `EXISTS (SELECT 1 FROM oauth_requests r
	WHERE r.request_id = oauth_grants.request_id AND r.kind IN ('access', 'refresh')
		AND r.revoked_at IS NULL AND r.expires_at > ?)`

func scanGrant(scan func(...any) error) (Grant, error) {
	var g Grant
	var approved, used sql.NullInt64
	err := scan(&g.RequestID, &g.ID, &g.UserID, &g.ClientID, &g.ClientName, &g.ClientHost, &g.Redirect, &approved, &used)
	if err != nil {
		return Grant{}, mapErr(err)
	}
	g.ApprovedAt, g.LastUsedAt = fromMS(approved), fromMS(used)
	return g, nil
}

// LiveGrants lists the user's grants that have access now, newest approval first, at most limit.
func (s *Store) LiveGrants(ctx context.Context, userID string, now time.Time, limit int) ([]Grant, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT `+grantColumns+` FROM oauth_grants WHERE user_id = ? AND `+grantLive+`
		ORDER BY approved_at DESC, id LIMIT ?`, userID, now.UnixMilli(), limit)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var out []Grant
	for rows.Next() {
		g, err := scanGrant(rows.Scan)
		if err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

// GrantByRequest returns the grant a code or token belongs to.
func (s *Store) GrantByRequest(ctx context.Context, requestID string) (Grant, error) {
	return scanGrant(s.db.QueryRowContext(ctx,
		`SELECT `+grantColumns+` FROM oauth_grants WHERE request_id = ?`, requestID).Scan)
}

// GrantLive reports whether the grant has access now.
func (s *Store) GrantLive(ctx context.Context, requestID string, now time.Time) (bool, error) {
	var n int
	err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM oauth_grants WHERE request_id = ? AND `+grantLive, requestID, now.UnixMilli()).Scan(&n)
	return n > 0, err
}

// DeleteGrant removes one of the user's grants, with every code and token of it, in one
// transaction; no token can be written for it afterwards (PutOAuthToken). A grant of another
// user, or an unknown ID, changes nothing and reports false (FR-191).
func (s *Store) DeleteGrant(ctx context.Context, userID, id string) (bool, error) {
	removed := false
	err := s.immediate(ctx, func(conn *sql.Conn) error {
		var requestID string
		err := conn.QueryRowContext(ctx,
			`SELECT request_id FROM oauth_grants WHERE id = ? AND user_id = ?`, id, userID).Scan(&requestID)
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		if _, err := conn.ExecContext(ctx,
			`DELETE FROM oauth_requests WHERE request_id = ? AND user_id = ?`, requestID, userID); err != nil {
			return err
		}
		if _, err := conn.ExecContext(ctx, `DELETE FROM oauth_grants WHERE request_id = ?`, requestID); err != nil {
			return err
		}
		removed = true
		return nil
	})
	return removed, err
}

// TouchGrant records that the grant was used. The caller limits how often (FR-192).
func (s *Store) TouchGrant(ctx context.Context, requestID string, at time.Time) error {
	_, err := s.db.ExecContext(ctx, `UPDATE oauth_grants SET last_used_at = ? WHERE request_id = ?`, toMS(at), requestID)
	return err
}

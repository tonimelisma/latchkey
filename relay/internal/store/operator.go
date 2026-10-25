package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// Operator actions recorded in the operator log (FR-195).
const (
	OpSuspend   = "suspend"
	OpUnsuspend = "unsuspend"
	OpDelete    = "delete"
	OpBlock     = "block"
	OpUnblock   = "unblock"
)

// OperatorLogRetention is how long a record of an operator's action is kept (FR-199).
const OperatorLogRetention = 365 * 24 * time.Hour

// OperatorEntry is one command the relay's operator ran: who, what, when, about which address.
// UserID and DeviceID name the account's rows at that moment, so the running relay can close
// its connections (FR-198).
type OperatorEntry struct {
	ID       int64
	At       time.Time
	Actor    string
	Action   string
	Email    string
	UserID   string
	DeviceID string
	Detail   string
}

type execer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

func logOperator(ctx context.Context, q execer, e OperatorEntry) error {
	_, err := q.ExecContext(ctx, `
		INSERT INTO operator_log (at, actor, action, email, user_id, device_id, detail) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		toMS(e.At), e.Actor, e.Action, e.Email, e.UserID, e.DeviceID, e.Detail)
	return err
}

// target finds the account for an operator command: the user, whether it is suspended, and its
// paired Mac if any.
func target(ctx context.Context, q execer, email string) (u User, deviceID string, err error) {
	var suspended sql.NullInt64
	err = q.QueryRowContext(ctx,
		`SELECT id, email, suspended_at FROM users WHERE email = ? AND deleted_at IS NULL`, email).Scan(&u.ID, &u.Email, &suspended)
	if err != nil {
		return User{}, "", mapErr(err)
	}
	u.SuspendedAt = fromMS(suspended)
	err = q.QueryRowContext(ctx,
		`SELECT id FROM devices WHERE user_id = ? AND revoked_at IS NULL`, u.ID).Scan(&deviceID)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return User{}, "", err
	}
	return u, deviceID, nil
}

// suspend marks the user suspended and ends what a suspension ends at once (FR-196): browser
// sign-ins, emailed codes, and every Claude app's codes, tokens, and grants. The Mac's pairing,
// the passkeys, and the activity log stay.
func suspend(ctx context.Context, q execer, userID, reason string, now time.Time) error {
	for _, stmt := range []string{
		`DELETE FROM web_sessions WHERE user_id = ?`,
		`DELETE FROM email_tokens WHERE user_id = ? AND used_at IS NULL`,
		`DELETE FROM pairing_codes WHERE user_id = ?`,
		`DELETE FROM oauth_requests WHERE user_id = ?`,
		`DELETE FROM oauth_grants WHERE user_id = ?`,
	} {
		if _, err := q.ExecContext(ctx, stmt, userID); err != nil {
			return err
		}
	}
	_, err := q.ExecContext(ctx,
		`UPDATE users SET suspended_at = ?, suspended_reason = ? WHERE id = ?`, toMS(now), reason, userID)
	return err
}

// SuspendUser suspends the account with that (normalized) email address. No such account is
// ErrNotFound; one that is suspended already is left as it is (changed false).
func (s *Store) SuspendUser(ctx context.Context, email, reason, actor string, now time.Time) (u User, changed bool, err error) {
	now = now.UTC().Truncate(time.Millisecond)
	err = s.immediate(ctx, func(conn *sql.Conn) error {
		var deviceID string
		var err error
		if u, deviceID, err = target(ctx, conn, email); err != nil {
			return err
		}
		if !u.SuspendedAt.IsZero() {
			return nil
		}
		if err := suspend(ctx, conn, u.ID, reason, now); err != nil {
			return err
		}
		changed = true
		return logOperator(ctx, conn, OperatorEntry{
			At: now, Actor: actor, Action: OpSuspend, Email: email, UserID: u.ID, DeviceID: deviceID, Detail: reason,
		})
	})
	if err != nil {
		return User{}, false, err
	}
	return u, changed, nil
}

// UnsuspendUser lifts a suspension: the Owner can sign in again; Claude must be approved again.
func (s *Store) UnsuspendUser(ctx context.Context, email, actor string, now time.Time) (u User, changed bool, err error) {
	now = now.UTC().Truncate(time.Millisecond)
	err = s.immediate(ctx, func(conn *sql.Conn) error {
		var deviceID string
		var err error
		if u, deviceID, err = target(ctx, conn, email); err != nil {
			return err
		}
		if u.SuspendedAt.IsZero() {
			return nil
		}
		if _, err := conn.ExecContext(ctx,
			`UPDATE users SET suspended_at = NULL, suspended_reason = '' WHERE id = ?`, u.ID); err != nil {
			return err
		}
		changed = true
		return logOperator(ctx, conn, OperatorEntry{
			At: now, Actor: actor, Action: OpUnsuspend, Email: email, UserID: u.ID, DeviceID: deviceID,
		})
	})
	if err != nil {
		return User{}, false, err
	}
	return u, changed, nil
}

// DeleteUserByOperator deletes the account and everything about it, as the Owner's own Delete
// account does (FR-045); the operator log keeps the record.
func (s *Store) DeleteUserByOperator(ctx context.Context, email, actor string, now time.Time) (u User, err error) {
	now = now.UTC().Truncate(time.Millisecond)
	err = s.immediate(ctx, func(conn *sql.Conn) error {
		var deviceID string
		var err error
		if u, deviceID, err = target(ctx, conn, email); err != nil {
			return err
		}
		if _, err := conn.ExecContext(ctx, `DELETE FROM users WHERE id = ?`, u.ID); err != nil {
			return err
		}
		return logOperator(ctx, conn, OperatorEntry{
			At: now, Actor: actor, Action: OpDelete, Email: email, UserID: u.ID, DeviceID: deviceID,
		})
	})
	if err != nil {
		return User{}, err
	}
	return u, nil
}

// BlockedEmail is an address that can't sign up or sign in (FR-197).
type BlockedEmail struct {
	Email  string
	At     time.Time
	Reason string
}

// BlockEmail blocks the (normalized) address and suspends its account if it has one. changed is
// false when it was blocked already.
func (s *Store) BlockEmail(ctx context.Context, email, reason, actor string, now time.Time) (changed, suspended bool, err error) {
	now = now.UTC().Truncate(time.Millisecond)
	err = s.immediate(ctx, func(conn *sql.Conn) error {
		res, err := conn.ExecContext(ctx,
			`INSERT OR IGNORE INTO blocked_emails (email, blocked_at, reason) VALUES (?, ?, ?)`, email, toMS(now), reason)
		if err != nil {
			return err
		}
		if n, err := res.RowsAffected(); err != nil || n == 0 {
			return err
		}
		changed = true
		entry := OperatorEntry{At: now, Actor: actor, Action: OpBlock, Email: email, Detail: reason}
		u, deviceID, err := target(ctx, conn, email)
		switch {
		case errors.Is(err, ErrNotFound):
		case err != nil:
			return err
		default:
			entry.UserID, entry.DeviceID = u.ID, deviceID
			if u.SuspendedAt.IsZero() {
				if err := suspend(ctx, conn, u.ID, "address blocked: "+reason, now); err != nil {
					return err
				}
			}
			suspended = true
		}
		return logOperator(ctx, conn, entry)
	})
	if err != nil {
		return false, false, err
	}
	return changed, suspended, nil
}

// UnblockEmail removes a block. An account suspended with it stays suspended.
func (s *Store) UnblockEmail(ctx context.Context, email, actor string, now time.Time) (changed bool, err error) {
	now = now.UTC().Truncate(time.Millisecond)
	err = s.immediate(ctx, func(conn *sql.Conn) error {
		res, err := conn.ExecContext(ctx, `DELETE FROM blocked_emails WHERE email = ?`, email)
		if err != nil {
			return err
		}
		if n, err := res.RowsAffected(); err != nil || n == 0 {
			return err
		}
		changed = true
		return logOperator(ctx, conn, OperatorEntry{At: now, Actor: actor, Action: OpUnblock, Email: email})
	})
	return changed, err
}

// EmailBlocked reports whether the (normalized) address is blocked.
func (s *Store) EmailBlocked(ctx context.Context, email string) (bool, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM blocked_emails WHERE email = ?`, email).Scan(&n)
	return n > 0, err
}

// BlockedEmails lists the blocked addresses, in order of address.
func (s *Store) BlockedEmails(ctx context.Context) ([]BlockedEmail, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT email, blocked_at, reason FROM blocked_emails ORDER BY email`)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var out []BlockedEmail
	for rows.Next() {
		var b BlockedEmail
		var at sql.NullInt64
		if err := rows.Scan(&b.Email, &at, &b.Reason); err != nil {
			return nil, err
		}
		b.At = fromMS(at)
		out = append(out, b)
	}
	return out, rows.Err()
}

// AccountSummary is one line of the operator's list of accounts: no secrets.
type AccountSummary struct {
	Email      string
	CreatedAt  time.Time
	LastSignIn time.Time // the newest passkey use or browser sign-in still on record; zero if none
	Verified   bool
	Suspended  bool
	HasMac     bool
	Approvals  int // Claude apps with access now
}

// Accounts lists every account, in order of address.
func (s *Store) Accounts(ctx context.Context, now time.Time) ([]AccountSummary, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT u.email, u.created_at, u.email_verified_at IS NOT NULL, u.suspended_at IS NOT NULL,
			MAX(COALESCE((SELECT MAX(last_used_at) FROM passkeys p WHERE p.user_id = u.id), 0),
				COALESCE((SELECT MAX(created_at) FROM web_sessions w WHERE w.user_id = u.id), 0)),
			EXISTS (SELECT 1 FROM devices d WHERE d.user_id = u.id AND d.revoked_at IS NULL),
			(SELECT COUNT(*) FROM oauth_grants WHERE oauth_grants.user_id = u.id AND `+grantLive+`)
		FROM users u WHERE u.deleted_at IS NULL ORDER BY u.email`, now.UnixMilli())
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var out []AccountSummary
	for rows.Next() {
		var a AccountSummary
		var created sql.NullInt64
		var last int64
		if err := rows.Scan(&a.Email, &created, &a.Verified, &a.Suspended, &last, &a.HasMac, &a.Approvals); err != nil {
			return nil, err
		}
		a.CreatedAt = fromMS(created)
		if last > 0 {
			a.LastSignIn = time.UnixMilli(last).UTC()
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// LastOperatorLogID is the newest entry's ID, or zero.
func (s *Store) LastOperatorLogID(ctx context.Context) (int64, error) {
	var id sql.NullInt64
	err := s.db.QueryRowContext(ctx, `SELECT MAX(id) FROM operator_log`).Scan(&id)
	return id.Int64, err
}

// OperatorLogAfter returns the entries newer than the given ID, oldest first. The running relay
// polls it to act on commands run beside it (FR-198).
func (s *Store) OperatorLogAfter(ctx context.Context, id int64) ([]OperatorEntry, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, at, actor, action, email, user_id, device_id, detail FROM operator_log WHERE id > ? ORDER BY id`, id)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var out []OperatorEntry
	for rows.Next() {
		var e OperatorEntry
		var at sql.NullInt64
		if err := rows.Scan(&e.ID, &at, &e.Actor, &e.Action, &e.Email, &e.UserID, &e.DeviceID, &e.Detail); err != nil {
			return nil, err
		}
		e.At = fromMS(at)
		out = append(out, e)
	}
	return out, rows.Err()
}

// PurgeOperatorLog deletes entries from before the cutoff (FR-199).
func (s *Store) PurgeOperatorLog(ctx context.Context, before time.Time) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM operator_log WHERE at < ?`, before.UnixMilli())
	return err
}

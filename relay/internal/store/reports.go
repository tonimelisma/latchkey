package store

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"time"
)

// OutboxReport is a problem report sealed to the developer's key, waiting for the intake
// (spec 014 FR-1413, FR-1414). The relay can't read it.
type OutboxReport struct {
	ID      string
	UserID  string
	Created time.Time
	Sealed  []byte
	// Small is the report without its chat's calls, logs and pages, sealed too, for an intake
	// that takes only 64 KB (FR-1451); nil when Sealed is already small.
	Small []byte
	Tries int
}

// AddReport puts a sealed report in the outbox, due at once.
func (s *Store) AddReport(ctx context.Context, r OutboxReport) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO report_outbox (id, user_id, created, sealed, small, tries, next_try) VALUES (?, ?, ?, ?, ?, 0, ?)`,
		r.ID, r.UserID, toMS(r.Created), r.Sealed, r.Small, toMS(r.Created))
	return mapErr(err)
}

// DueReports gives the reports due by now, oldest first, at most limit.
func (s *Store) DueReports(ctx context.Context, now time.Time, limit int) ([]OutboxReport, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, user_id, created, sealed, small, tries FROM report_outbox WHERE next_try <= ? ORDER BY next_try, id LIMIT ?`,
		toMS(now), limit)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var out []OutboxReport
	for rows.Next() {
		var r OutboxReport
		var created sql.NullInt64
		if err := rows.Scan(&r.ID, &r.UserID, &created, &r.Sealed, &r.Small, &r.Tries); err != nil {
			return nil, err
		}
		r.Created = fromMS(created)
		out = append(out, r)
	}
	return out, rows.Err()
}

// ReportDone removes a report: the intake accepted it, refused it for good, or it waited too
// long (FR-1414).
func (s *Store) ReportDone(ctx context.Context, id string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM report_outbox WHERE id = ?`, id)
	return err
}

// ReportUseSmall replaces a report with its small version, due at once (FR-1451): the intake
// refused the whole one as too large. It reports whether there was a small version.
func (s *Store) ReportUseSmall(ctx context.Context, id string) (bool, error) {
	res, err := s.db.ExecContext(ctx,
		`UPDATE report_outbox SET sealed = small, small = NULL WHERE id = ? AND small IS NOT NULL`, id)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n == 1, err
}

// ReportRetry counts a failed delivery and makes the report due again at next.
func (s *Store) ReportRetry(ctx context.Context, id string, next time.Time) error {
	_, err := s.db.ExecContext(ctx, `UPDATE report_outbox SET tries = tries + 1, next_try = ? WHERE id = ?`, toMS(next), id)
	return err
}

// DropUserReports removes the account's waiting reports: the Owner turned sharing off
// (FR-1403).
func (s *Store) DropUserReports(ctx context.Context, userID string) (int64, error) {
	res, err := s.db.ExecContext(ctx, `DELETE FROM report_outbox WHERE user_id = ?`, userID)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// ReporterTag groups one account's reports without saying whose they are (FR-1412): a keyed
// hash of the account's id under a key derived from the relay's key file, so it is stable on
// this relay and means nothing elsewhere.
func (s *Store) ReporterTag(userID string) (string, error) {
	k, err := s.DeriveKey("latchkey reporter tag")
	if err != nil {
		return "", err
	}
	m := hmac.New(sha256.New, k)
	m.Write([]byte(userID))
	return hex.EncodeToString(m.Sum(nil)[:8]), nil
}

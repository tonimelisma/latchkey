package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"
)

// Feedback is one report Claude filed (spec 001 FR-690, FR-691).
type Feedback struct {
	ID      string
	UserID  string
	At      time.Time
	Client  string
	Machine string
	Summary string
	Details string
}

// feedbackText is what is sealed: everything but the id, account, and time.
type feedbackText struct {
	Client  string `json:"client"`
	Machine string `json:"machine"`
	Summary string `json:"summary"`
	Details string `json:"details"`
}

func feedbackSealName(id string) string { return "feedback/" + id }

// AddFeedback keeps a report, its text sealed under the key file (FR-691).
func (s *Store) AddFeedback(ctx context.Context, f Feedback) error {
	if s.aead == nil {
		return fmt.Errorf("feedback: the store has no key file")
	}
	plain, err := json.Marshal(feedbackText{Client: f.Client, Machine: f.Machine, Summary: f.Summary, Details: f.Details})
	if err != nil {
		return err
	}
	sealed, err := s.seal(feedbackSealName(f.ID), plain)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx,
		`INSERT INTO feedback (id, user_id, at, sealed) VALUES (?, ?, ?, ?)`,
		f.ID, f.UserID, toMS(f.At), sealed)
	return mapErr(err)
}

// WaitingFeedback returns the account's reports no Mac has saved yet, oldest first, at most
// limit. A report whose text can't be opened (a different key file) is left out.
func (s *Store) WaitingFeedback(ctx context.Context, userID string, limit int) ([]Feedback, error) {
	if s.aead == nil {
		return nil, fmt.Errorf("feedback: the store has no key file")
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, at, sealed FROM feedback WHERE user_id = ? AND delivered_at IS NULL ORDER BY at, id LIMIT ?`,
		userID, limit)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var out []Feedback
	for rows.Next() {
		var (
			id     string
			at     sql.NullInt64
			sealed []byte
		)
		if err := rows.Scan(&id, &at, &sealed); err != nil {
			return nil, err
		}
		plain, err := s.unseal(feedbackSealName(id), sealed)
		if err != nil {
			continue
		}
		var t feedbackText
		if json.Unmarshal(plain, &t) != nil {
			continue
		}
		out = append(out, Feedback{
			ID: id, UserID: userID, At: fromMS(at),
			Client: t.Client, Machine: t.Machine, Summary: t.Summary, Details: t.Details,
		})
	}
	return out, rows.Err()
}

// FeedbackDelivered marks the account's reports with these ids as saved by a Mac (FR-692);
// ids of other accounts are left alone.
func (s *Store) FeedbackDelivered(ctx context.Context, userID string, ids []string, now time.Time) error {
	for _, id := range ids {
		if _, err := s.db.ExecContext(ctx,
			`UPDATE feedback SET delivered_at = ? WHERE id = ? AND user_id = ? AND delivered_at IS NULL`,
			toMS(now), id, userID); err != nil {
			return err
		}
	}
	return nil
}

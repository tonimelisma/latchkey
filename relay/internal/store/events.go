package store

import (
	"context"
	"database/sql"
	"time"
)

// Event is one entry of the relay's event record (FR-631): what happened, when, to which account
// and Mac. Detail is fixed words chosen by the relay (an outcome, a reason, a version), never
// content, tokens, codes, keys, or addresses. Counted events (CountEvent) cover an hour: At is the
// first, LastAt the last, Count how many.
type Event struct {
	ID       int64
	At       time.Time
	Kind     string
	UserID   string // "" without an account
	DeviceID string
	Detail   string
	Count    int
	LastAt   time.Time
}

// AddEvent records one event. Events are never deleted by age (FR-630); deleting the account
// deletes its events.
func (s *Store) AddEvent(ctx context.Context, e Event) error {
	at := e.At.UTC().UnixMilli()
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO events (at, kind, user_id, device_id, detail, last_at) VALUES (?, ?, ?, ?, ?, ?)`,
		at, e.Kind, nullString(e.UserID), e.DeviceID, e.Detail, at)
	return mapErr(err)
}

// CountEvent adds one to the row of the event's hour, kind, account, Mac, and detail, making the
// row if there is none yet, and reports whether it made one.
func (s *Store) CountEvent(ctx context.Context, e Event) (first bool, err error) {
	at := e.At.UTC().UnixMilli()
	hour := e.At.UTC().Truncate(time.Hour).UnixMilli()
	err = s.immediate(ctx, func(conn *sql.Conn) error {
		res, err := conn.ExecContext(ctx, `
			UPDATE events SET count = count + 1, last_at = max(last_at, ?)
			WHERE hour = ? AND kind = ? AND detail = ? AND device_id = ? AND user_id IS ?`,
			at, hour, e.Kind, e.Detail, e.DeviceID, nullString(e.UserID))
		if err != nil {
			return err
		}
		if n, err := res.RowsAffected(); err != nil || n > 0 {
			return err
		}
		first = true
		_, err = conn.ExecContext(ctx, `
			INSERT INTO events (at, kind, user_id, device_id, detail, hour, last_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
			at, e.Kind, nullString(e.UserID), e.DeviceID, e.Detail, hour, at)
		return err
	})
	return first, mapErr(err)
}

// Events returns the account's most recent events, newest first; userID "" returns the events
// without an account.
func (s *Store) Events(ctx context.Context, userID string, limit int) ([]Event, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, at, kind, coalesce(user_id, ''), device_id, detail, count, last_at
		FROM events WHERE user_id IS ? ORDER BY at DESC, id DESC LIMIT ?`, nullString(userID), limit)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }() // read-only; rows.Err reports failures
	var out []Event
	for rows.Next() {
		var e Event
		var at, last int64
		if err := rows.Scan(&e.ID, &at, &e.Kind, &e.UserID, &e.DeviceID, &e.Detail, &e.Count, &last); err != nil {
			return nil, err
		}
		e.At, e.LastAt = time.UnixMilli(at).UTC(), time.UnixMilli(last).UTC()
		out = append(out, e)
	}
	return out, rows.Err()
}

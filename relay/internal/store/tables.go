package store

import (
	"context"
	"database/sql"
	"time"
)

// User is an Owner account.
type User struct {
	ID              string
	Email           string
	EmailVerifiedAt time.Time
	CreatedAt       time.Time
	// SuspendedAt is when the relay's operator suspended the account (zero: not suspended), and
	// SuspendedReason what they gave as the reason (FR-196).
	SuspendedAt     time.Time
	SuspendedReason string
}

// CreateUser adds an unverified user. A taken email is ErrConflict.
func (s *Store) CreateUser(ctx context.Context, email string, now time.Time) (User, error) {
	u := User{ID: newID("usr_"), Email: email, CreatedAt: now.UTC().Truncate(time.Millisecond)}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO users (id, email, created_at) VALUES (?, ?, ?)`,
		u.ID, u.Email, toMS(u.CreatedAt))
	if err != nil {
		return User{}, mapErr(err)
	}
	return u, nil
}

// User returns a user by ID.
func (s *Store) User(ctx context.Context, id string) (User, error) {
	var u User
	var verified, created, suspended sql.NullInt64
	err := s.db.QueryRowContext(ctx,
		`SELECT id, email, email_verified_at, created_at, suspended_at, suspended_reason
		FROM users WHERE id = ? AND deleted_at IS NULL`, id,
	).Scan(&u.ID, &u.Email, &verified, &created, &suspended, &u.SuspendedReason)
	if err != nil {
		return User{}, mapErr(err)
	}
	u.EmailVerifiedAt, u.CreatedAt, u.SuspendedAt = fromMS(verified), fromMS(created), fromMS(suspended)
	return u, nil
}

// Device is a paired Mac. PublicKey is a PKIX DER P-256 key, nil once revoked.
type Device struct {
	ID         string
	UserID     string
	Name       string
	PublicKey  []byte
	AppVersion string
	OSVersion  string
	CreatedAt  time.Time
	RevokedAt  time.Time
}

// NewDevice is what pairing supplies.
type NewDevice struct {
	UserID    string
	Name      string
	PublicKey []byte
}

// CreateDevice pairs a device. A user with an active device already is ErrConflict.
func (s *Store) CreateDevice(ctx context.Context, nd NewDevice, now time.Time) (Device, error) {
	d := Device{
		ID: newID("dev_"), UserID: nd.UserID, Name: nd.Name, PublicKey: nd.PublicKey,
		CreatedAt: now.UTC().Truncate(time.Millisecond),
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO devices (id, user_id, name, public_key, created_at) VALUES (?, ?, ?, ?, ?)`,
		d.ID, d.UserID, d.Name, d.PublicKey, toMS(d.CreatedAt))
	if err != nil {
		return Device{}, mapErr(err)
	}
	return d, nil
}

const deviceColumns = `id, user_id, name, public_key, app_version, os_version, created_at, revoked_at`

func scanDevice(row *sql.Row) (Device, error) {
	var d Device
	var created, revoked sql.NullInt64
	err := row.Scan(&d.ID, &d.UserID, &d.Name, &d.PublicKey, &d.AppVersion, &d.OSVersion, &created, &revoked)
	if err != nil {
		return Device{}, mapErr(err)
	}
	d.CreatedAt, d.RevokedAt = fromMS(created), fromMS(revoked)
	return d, nil
}

// Device returns a device by ID, revoked or not.
func (s *Store) Device(ctx context.Context, id string) (Device, error) {
	return scanDevice(s.db.QueryRowContext(ctx, `SELECT `+deviceColumns+` FROM devices WHERE id = ?`, id))
}

// ActiveDevice returns the user's unrevoked device.
func (s *Store) ActiveDevice(ctx context.Context, userID string) (Device, error) {
	return scanDevice(s.db.QueryRowContext(ctx,
		`SELECT `+deviceColumns+` FROM devices WHERE user_id = ? AND revoked_at IS NULL`, userID))
}

// UpdateDeviceVersions records the versions the device reported in hello.
func (s *Store) UpdateDeviceVersions(ctx context.Context, id, appVersion, osVersion string) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE devices SET app_version = ?, os_version = ? WHERE id = ?`, appVersion, osVersion, id)
	if err != nil {
		return err
	}
	return requireOneRow(res)
}

// RevokeDevice deletes the device's public key. An unknown or already revoked device is ErrNotFound.
func (s *Store) RevokeDevice(ctx context.Context, id string, now time.Time) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE devices SET public_key = NULL, revoked_at = ? WHERE id = ? AND revoked_at IS NULL`,
		toMS(now.UTC().Truncate(time.Millisecond)), id)
	if err != nil {
		return err
	}
	return requireOneRow(res)
}

// DeviceState is the latest known state of a device; no history is kept (FR-020).
type DeviceState struct {
	DeviceID      string
	Online        bool
	ConnectedAt   time.Time
	LastSeenAt    time.Time
	OfflineReason string
	StateJSON     []byte
	ToolsJSON     []byte
}

// PutDeviceState replaces the device's state row.
func (s *Store) PutDeviceState(ctx context.Context, st DeviceState) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO device_state (device_id, online, connected_at, last_seen_at, offline_reason, state_json, tools_json)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (device_id) DO UPDATE SET
			online = excluded.online, connected_at = excluded.connected_at,
			last_seen_at = excluded.last_seen_at, offline_reason = excluded.offline_reason,
			state_json = excluded.state_json, tools_json = excluded.tools_json`,
		st.DeviceID, st.Online, toMS(st.ConnectedAt), toMS(st.LastSeenAt), st.OfflineReason,
		nullBytes(st.StateJSON), nullBytes(st.ToolsJSON))
	return mapErr(err)
}

// PutDeviceStatus updates the device's state row except its tool list, which is large and
// changes rarely. ErrNotFound if the device has no row yet.
func (s *Store) PutDeviceStatus(ctx context.Context, st DeviceState) error {
	res, err := s.db.ExecContext(ctx, `
		UPDATE device_state SET online = ?, connected_at = ?, last_seen_at = ?, offline_reason = ?, state_json = ?
		WHERE device_id = ?`,
		st.Online, toMS(st.ConnectedAt), toMS(st.LastSeenAt), st.OfflineReason, nullBytes(st.StateJSON), st.DeviceID)
	if err != nil {
		return mapErr(err)
	}
	return requireOneRow(res)
}

// DeviceState returns the device's state row.
func (s *Store) DeviceState(ctx context.Context, deviceID string) (DeviceState, error) {
	var st DeviceState
	var connected, seen sql.NullInt64
	err := s.db.QueryRowContext(ctx, `
		SELECT device_id, online, connected_at, last_seen_at, offline_reason, state_json, tools_json
		FROM device_state WHERE device_id = ?`, deviceID,
	).Scan(&st.DeviceID, &st.Online, &connected, &seen, &st.OfflineReason, &st.StateJSON, &st.ToolsJSON)
	if err != nil {
		return DeviceState{}, mapErr(err)
	}
	st.ConnectedAt, st.LastSeenAt = fromMS(connected), fromMS(seen)
	return st, nil
}

// Audit outcomes (FR-022).
const (
	OutcomeOK      = "ok"
	OutcomeError   = "error"
	OutcomeTimeout = "timeout"
	OutcomeOffline = "offline"
)

// AuditEntry is one tool call's metadata. It never holds arguments or results.
type AuditEntry struct {
	UserID   string
	DeviceID string // empty if no device was paired
	At       time.Time
	Tool     string
	Surface  string
	Outcome  string
	Duration time.Duration
	// CallID is the call's id, unique for all time (FR-632); "" for entries from before call ids
	// and for removals the Mac app asked for.
	CallID string
}

// AddAudit records a tool call. Entries are kept until the account is deleted; nothing is
// deleted by age (FR-024, FR-630).
func (s *Store) AddAudit(ctx context.Context, e AuditEntry) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO audit_log (user_id, device_id, at, tool, surface, outcome, duration_ms, call_id)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		e.UserID, nullString(e.DeviceID), toMS(e.At), e.Tool, e.Surface, e.Outcome, e.Duration.Milliseconds(), e.CallID)
	return mapErr(err)
}

// AuditForUser returns the user's most recent entries, newest first.
func (s *Store) AuditForUser(ctx context.Context, userID string, limit int) ([]AuditEntry, error) {
	return s.queryAudit(ctx, `
		SELECT user_id, device_id, at, tool, surface, outcome, duration_ms, call_id
		FROM audit_log WHERE user_id = ? ORDER BY at DESC, id DESC LIMIT ?`, userID, limit)
}

func (s *Store) queryAudit(ctx context.Context, query string, args ...any) ([]AuditEntry, error) {
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }() // read-only; rows.Err reports failures
	var out []AuditEntry
	for rows.Next() {
		var e AuditEntry
		var device sql.NullString
		var at sql.NullInt64
		var ms int64
		if err := rows.Scan(&e.UserID, &device, &at, &e.Tool, &e.Surface, &e.Outcome, &ms, &e.CallID); err != nil {
			return nil, err
		}
		e.DeviceID, e.At, e.Duration = device.String, fromMS(at), time.Duration(ms)*time.Millisecond
		out = append(out, e)
	}
	return out, rows.Err()
}

// AuditForDevice returns one page of the Mac's audit for the comparison (FR-634): entries at or
// after since (Unix milliseconds), oldest first, at most limit, and the since of the next page
// (nil when there is none). A page never ends inside a millisecond whose entries go on beyond
// it: those entries start the next page instead, so paging skips nothing. Only when one
// millisecond alone holds more than limit entries does the page end in it, and the rest of that
// millisecond is skipped.
func (s *Store) AuditForDevice(ctx context.Context, deviceID string, since int64, limit int) ([]AuditEntry, *int64, error) {
	rows, err := s.queryAudit(ctx, `
		SELECT user_id, device_id, at, tool, surface, outcome, duration_ms, call_id
		FROM audit_log WHERE device_id = ? AND at >= ? ORDER BY at, id LIMIT ?`, deviceID, since, limit+1)
	if err != nil || len(rows) <= limit {
		return rows, nil, err
	}
	page := rows[:limit]
	boundary := rows[limit].At
	cut := len(page)
	for cut > 0 && page[cut-1].At.Equal(boundary) {
		cut--
	}
	if cut == 0 { // one millisecond holds more than a page
		next := boundary.UnixMilli() + 1
		return page, &next, nil
	}
	next := boundary.UnixMilli()
	return page[:cut], &next, nil
}

// MarkAllOffline clears the online flag everywhere. The hub calls it at startup, since no
// connection survives a relay restart.
func (s *Store) MarkAllOffline(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `UPDATE device_state SET online = 0 WHERE online = 1`)
	return err
}

package store

import (
	"context"
	"database/sql"
	"fmt"
	"math"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
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

// Device is a paired machine: a Mac or a Linux server (spec 010). PublicKey is a PKIX DER P-256
// key, nil once revoked.
type Device struct {
	ID         string
	UserID     string
	Name       string
	Kind       string // "mac" or "linux"
	PublicKey  []byte
	AppVersion string
	OSVersion  string
	CreatedAt  time.Time
	RevokedAt  time.Time
}

// Device kinds.
const (
	KindMac   = "mac"
	KindLinux = "linux"
)

// NewDevice is what pairing supplies.
type NewDevice struct {
	UserID    string
	Name      string
	Kind      string // KindMac when empty
	PublicKey []byte
}

// MaxDeviceName is the longest machine name kept, in characters.
const MaxDeviceName = 100

// CleanDeviceName makes a machine's self-chosen name safe to store and show: trimmed, without
// control or formatting characters, at most MaxDeviceName characters; fallback when nothing is
// left.
func CleanDeviceName(n, fallback string) string {
	if !utf8.ValidString(n) {
		return fallback
	}
	var b strings.Builder
	count := 0
	for _, r := range strings.TrimSpace(n) {
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) {
			continue
		}
		if count == MaxDeviceName {
			break
		}
		b.WriteRune(r)
		count++
	}
	if s := strings.TrimSpace(b.String()); s != "" {
		return s
	}
	return fallback
}

// deviceNames serializes choosing a name, so two machines paired at once can't both take it.
var deviceNames sync.Mutex

// CreateDevice pairs a machine; the account's other machines stay paired (spec 010 FR-1001). Its
// name is nd.Name, or that name with " 2", " 3", … when another active machine of the account
// has it (FR-1002).
func (s *Store) CreateDevice(ctx context.Context, nd NewDevice, now time.Time) (Device, error) {
	kind := nd.Kind
	if kind == "" {
		kind = KindMac
	}
	deviceNames.Lock()
	defer deviceNames.Unlock()
	name, err := s.freeName(ctx, nd.UserID, "", nd.Name)
	if err != nil {
		return Device{}, err
	}
	d := Device{
		ID: newID("dev_"), UserID: nd.UserID, Name: name, Kind: kind, PublicKey: nd.PublicKey,
		CreatedAt: now.UTC().Truncate(time.Millisecond),
	}
	_, err = s.db.ExecContext(ctx,
		`INSERT INTO devices (id, user_id, name, kind, public_key, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
		d.ID, d.UserID, d.Name, d.Kind, d.PublicKey, toMS(d.CreatedAt))
	if err != nil {
		return Device{}, mapErr(err)
	}
	return d, nil
}

// RenameDevice gives the device the wanted name, made unique among the account's active machines
// as in CreateDevice, and returns the name it kept. A name the device already has is kept as is.
func (s *Store) RenameDevice(ctx context.Context, id, wanted string) (string, error) {
	deviceNames.Lock()
	defer deviceNames.Unlock()
	d, err := s.Device(ctx, id)
	if err != nil {
		return "", err
	}
	name, err := s.freeName(ctx, d.UserID, d.ID, wanted)
	if err != nil {
		return "", err
	}
	if name == d.Name {
		return name, nil
	}
	res, err := s.db.ExecContext(ctx, `UPDATE devices SET name = ? WHERE id = ?`, name, id)
	if err != nil {
		return "", err
	}
	return name, requireOneRow(res)
}

// freeName is wanted, or wanted with the first free number appended, compared without regard to
// letter case among the user's active devices other than except.
//
// NameKey is the one comparison of machine names, used both here and when a call names its
// machine, so the two can never disagree (security review, 2026-10-31): each letter is replaced
// by the smallest letter Unicode's case folding equates it with (K, k, and the Kelvin sign alike),
// which is exactly strings.EqualFold's sameness.
func NameKey(name string) string {
	return strings.Map(func(r rune) rune {
		smallest := r
		for f := unicode.SimpleFold(r); f != r; f = unicode.SimpleFold(f) {
			smallest = min(smallest, f)
		}
		return smallest
	}, strings.TrimSpace(name))
}

func (s *Store) freeName(ctx context.Context, userID, except, wanted string) (string, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT name FROM devices WHERE user_id = ? AND revoked_at IS NULL AND id != ?`, userID, except)
	if err != nil {
		return "", err
	}
	defer func() { _ = rows.Close() }()
	taken := map[string]bool{}
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			return "", err
		}
		taken[NameKey(n)] = true
	}
	if err := rows.Err(); err != nil {
		return "", err
	}
	name := wanted
	for i := 2; taken[NameKey(name)]; i++ {
		name = fmt.Sprintf("%s %d", wanted, i)
	}
	return name, nil
}

const deviceColumns = `id, user_id, name, kind, public_key, app_version, os_version, created_at, revoked_at`

type scanner interface{ Scan(dest ...any) error }

func scanDevice(row scanner) (Device, error) {
	var d Device
	var created, revoked sql.NullInt64
	err := row.Scan(&d.ID, &d.UserID, &d.Name, &d.Kind, &d.PublicKey, &d.AppVersion, &d.OSVersion, &created, &revoked)
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

// ActiveDevices returns the user's paired machines, oldest pairing first (spec 010).
func (s *Store) ActiveDevices(ctx context.Context, userID string) ([]Device, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT `+deviceColumns+` FROM devices WHERE user_id = ? AND revoked_at IS NULL ORDER BY created_at, id`, userID)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var out []Device
	for rows.Next() {
		d, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
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

// AuditForUserBefore returns the user's most recent entries from before the given time (all of
// them when it is zero), newest first: one page of the account's activity page (FR-652).
func (s *Store) AuditForUserBefore(ctx context.Context, userID string, before time.Time, limit int) ([]AuditEntry, error) {
	return s.queryAudit(ctx, `
		SELECT user_id, device_id, at, tool, surface, outcome, duration_ms, call_id
		FROM audit_log WHERE user_id = ? AND at < ? ORDER BY at DESC, id DESC LIMIT ?`, userID, beforeMS(before), limit)
}

// beforeMS is a page's upper bound in Unix milliseconds; zero means no bound.
func beforeMS(before time.Time) int64 {
	if before.IsZero() {
		return math.MaxInt64
	}
	return before.UnixMilli()
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

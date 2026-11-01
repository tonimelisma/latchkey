package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// DevicePairing is a headless machine's request to be paired (spec 010 plan D7): it holds the
// name, kind, and public key the machine sent, until the Owner approves its short code and the
// machine collects its device ID. Codes are stored as hashes.
type DevicePairing struct {
	Name        string
	Kind        string
	PublicKey   []byte
	CreatedAt   time.Time
	ExpiresAt   time.Time
	PolledAt    time.Time // zero until the machine first asks
	ApprovedBy  string    // the approving user, "" while pending
	DeviceID    string    // set on approval
	CollectedAt time.Time // when the machine got its device ID
}

// Errors of the device pairing steps.
var (
	// ErrPairingPending: not approved yet.
	ErrPairingPending = errors.New("pairing pending")
	// ErrPairingExpired: unknown, expired, or already collected.
	ErrPairingExpired = errors.New("pairing expired")
)

// CreateDevicePairing stores a new request. A user code that collides with a live one is
// ErrConflict; the caller makes a new one.
func (s *Store) CreateDevicePairing(ctx context.Context, deviceCodeHash, userCodeHash []byte, p DevicePairing) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO device_pairings (device_code_hash, user_code_hash, name, kind, public_key, created_at, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		deviceCodeHash, userCodeHash, p.Name, p.Kind, p.PublicKey, toMS(p.CreatedAt), toMS(p.ExpiresAt))
	return mapErr(err)
}

const pairingColumns = `name, kind, public_key, created_at, expires_at, polled_at, approved_by, device_id, collected_at`

func scanPairing(row scanner) (DevicePairing, error) {
	var p DevicePairing
	var created, expires, polled, collected sql.NullInt64
	var approved, device sql.NullString
	if err := row.Scan(&p.Name, &p.Kind, &p.PublicKey, &created, &expires, &polled, &approved, &device, &collected); err != nil {
		return DevicePairing{}, mapErr(err)
	}
	p.CreatedAt, p.ExpiresAt, p.PolledAt, p.CollectedAt = fromMS(created), fromMS(expires), fromMS(polled), fromMS(collected)
	p.ApprovedBy, p.DeviceID = approved.String, device.String
	return p, nil
}

// DevicePairingByUserCode returns the live, unapproved request with this user code, for the
// approval page. Expired, approved, or unknown codes are ErrNotFound.
func (s *Store) DevicePairingByUserCode(ctx context.Context, userCodeHash []byte, now time.Time) (DevicePairing, error) {
	return scanPairing(s.db.QueryRowContext(ctx,
		`SELECT `+pairingColumns+` FROM device_pairings
		WHERE user_code_hash = ? AND expires_at > ? AND approved_by IS NULL`, userCodeHash, toMS(now)))
}

// ApproveDevicePairing pairs the machine under the user: it creates the device (named as
// CreateDevice names it) and records the approval, once. A code that is unknown, expired, or
// already approved is ErrNotFound.
func (s *Store) ApproveDevicePairing(ctx context.Context, userCodeHash []byte, userID string, now time.Time) (Device, error) {
	p, err := s.DevicePairingByUserCode(ctx, userCodeHash, now)
	if err != nil {
		return Device{}, err
	}
	d, err := s.CreateDevice(ctx, NewDevice{UserID: userID, Name: p.Name, Kind: p.Kind, PublicKey: p.PublicKey}, now)
	if err != nil {
		return Device{}, err
	}
	res, err := s.db.ExecContext(ctx,
		`UPDATE device_pairings SET approved_by = ?, device_id = ? WHERE user_code_hash = ? AND approved_by IS NULL`,
		userID, d.ID, userCodeHash)
	if err == nil {
		err = requireOneRow(res)
	}
	if err != nil { // approved twice at once: the second device goes again
		_ = s.RevokeDevice(ctx, d.ID, now)
		return Device{}, err
	}
	return d, nil
}

// PollDevicePairing is the machine asking whether its request was approved. It returns the
// device once approved (and marks it collected, so a second poll is ErrPairingExpired),
// ErrPairingPending while waiting, and ErrPairingExpired for an unknown, expired, or collected
// request. last is the previous poll's time (zero on the first), for the caller's slow-down
// rule.
func (s *Store) PollDevicePairing(ctx context.Context, deviceCodeHash []byte, now time.Time) (d Device, last time.Time, err error) {
	p, err := scanPairing(s.db.QueryRowContext(ctx,
		`SELECT `+pairingColumns+` FROM device_pairings WHERE device_code_hash = ?`, deviceCodeHash))
	if errors.Is(err, ErrNotFound) {
		return Device{}, time.Time{}, ErrPairingExpired
	}
	if err != nil {
		return Device{}, time.Time{}, err
	}
	if !p.CollectedAt.IsZero() || (p.DeviceID == "" && !now.Before(p.ExpiresAt)) {
		return Device{}, p.PolledAt, ErrPairingExpired
	}
	if _, err := s.db.ExecContext(ctx, `UPDATE device_pairings SET polled_at = ? WHERE device_code_hash = ?`,
		toMS(now), deviceCodeHash); err != nil {
		return Device{}, p.PolledAt, err
	}
	if p.DeviceID == "" {
		return Device{}, p.PolledAt, ErrPairingPending
	}
	res, err := s.db.ExecContext(ctx,
		`UPDATE device_pairings SET collected_at = ? WHERE device_code_hash = ? AND collected_at IS NULL`,
		toMS(now), deviceCodeHash)
	if err == nil {
		err = requireOneRow(res)
	}
	if err != nil {
		return Device{}, p.PolledAt, ErrPairingExpired
	}
	d, err = s.Device(ctx, p.DeviceID)
	return d, p.PolledAt, err
}

// PurgeDevicePairings deletes requests that expired more than an hour before now.
func (s *Store) PurgeDevicePairings(ctx context.Context, now time.Time) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM device_pairings WHERE expires_at < ?`, toMS(now.Add(-time.Hour)))
	return err
}

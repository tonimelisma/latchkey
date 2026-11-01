package store_test

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

var t0 = time.Date(2026, 10, 19, 17, 0, 0, 123_000_000, time.UTC)

func open(t *testing.T) *store.Store {
	t.Helper()
	s, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "relay.db"))
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, s.Close()) })
	return s
}

func newUser(t *testing.T, s *store.Store) store.User {
	t.Helper()
	u, err := s.CreateUser(context.Background(), "a@example.com", t0)
	require.NoError(t, err)
	return u
}

func newDevice(t *testing.T, s *store.Store, userID string) store.Device {
	t.Helper()
	d, err := s.CreateDevice(context.Background(), store.NewDevice{
		UserID: userID, Name: "Toni's MacBook", PublicKey: []byte("pkix-der"),
	}, t0)
	require.NoError(t, err)
	return d
}

func TestOpenIsIdempotent(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "relay.db")
	s, err := store.Open(ctx, path)
	require.NoError(t, err)
	u, err := s.CreateUser(ctx, "a@example.com", t0)
	require.NoError(t, err)
	require.NoError(t, s.Close())

	s, err = store.Open(ctx, path)
	require.NoError(t, err)
	defer func() { require.NoError(t, s.Close()) }()
	got, err := s.User(ctx, u.ID)
	require.NoError(t, err)
	assert.Equal(t, u, got)
}

func TestUsers(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	assert.True(t, strings.HasPrefix(u.ID, "usr_"), u.ID)
	assert.Equal(t, t0, u.CreatedAt)
	assert.True(t, u.EmailVerifiedAt.IsZero())

	_, err := s.CreateUser(ctx, "a@example.com", t0)
	require.ErrorIs(t, err, store.ErrConflict)

	_, err = s.User(ctx, "usr_missing")
	require.ErrorIs(t, err, store.ErrNotFound)
}

func TestDevices(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	d := newDevice(t, s, u.ID)
	assert.True(t, strings.HasPrefix(d.ID, "dev_"), d.ID)
	assert.Equal(t, []byte("pkix-der"), d.PublicKey)

	got, err := s.Device(ctx, d.ID)
	require.NoError(t, err)
	assert.Equal(t, d, got)

	active, err := s.ActiveDevices(ctx, u.ID)
	require.NoError(t, err)
	require.Len(t, active, 1)
	assert.Equal(t, d.ID, active[0].ID)
	assert.Equal(t, store.KindMac, active[0].Kind, "a pairing without a kind is a Mac")

	// Several machines per account (spec 010 FR-1001): a second pairing adds one.
	second, err := s.CreateDevice(ctx, store.NewDevice{UserID: u.ID, Name: "homeserver", Kind: store.KindLinux, PublicKey: []byte("k")}, t0.Add(time.Second))
	require.NoError(t, err)
	active, err = s.ActiveDevices(ctx, u.ID)
	require.NoError(t, err)
	require.Len(t, active, 2)
	assert.Equal(t, []string{d.ID, second.ID}, []string{active[0].ID, active[1].ID}, "oldest pairing first")
	assert.Equal(t, store.KindLinux, active[1].Kind)

	require.NoError(t, s.UpdateDeviceVersions(ctx, d.ID, "0.2.0", "26.2"))
	got, err = s.Device(ctx, d.ID)
	require.NoError(t, err)
	assert.Equal(t, "0.2.0", got.AppVersion)
	assert.Equal(t, "26.2", got.OSVersion)

	_, err = s.Device(ctx, "dev_missing")
	require.ErrorIs(t, err, store.ErrNotFound)
	_, err = s.CreateDevice(ctx, store.NewDevice{UserID: "usr_missing", Name: "x", PublicKey: []byte("k")}, t0)
	require.Error(t, err, "foreign keys must be enforced")
}

func TestRevokeDeletesPublicKey(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	d := newDevice(t, s, u.ID)

	revokedAt := t0.Add(time.Hour)
	require.NoError(t, s.RevokeDevice(ctx, d.ID, revokedAt))
	got, err := s.Device(ctx, d.ID)
	require.NoError(t, err)
	assert.Nil(t, got.PublicKey)
	assert.Equal(t, revokedAt, got.RevokedAt)

	active, err := s.ActiveDevices(ctx, u.ID)
	require.NoError(t, err)
	assert.Empty(t, active)
	require.ErrorIs(t, s.RevokeDevice(ctx, d.ID, revokedAt), store.ErrNotFound)

	// A new device can be paired after revocation.
	newDevice(t, s, u.ID)
}

// Names are unique among an account's paired machines, without regard to case; a revoked
// machine's name is free again, and another account's names don't count (spec 010 FR-1002).
func TestMachineNamesStayUnique(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	other, err := s.CreateUser(ctx, "other@example.com", t0)
	require.NoError(t, err)
	pair := func(userID, name string) store.Device {
		d, err := s.CreateDevice(ctx, store.NewDevice{UserID: userID, Name: name, Kind: store.KindLinux, PublicKey: []byte("k")}, t0)
		require.NoError(t, err)
		return d
	}
	a := pair(u.ID, "homeserver")
	assert.Equal(t, "homeserver", a.Name)
	b := pair(u.ID, "HomeServer")
	assert.Equal(t, "HomeServer 2", b.Name)
	c := pair(u.ID, "homeserver")
	assert.Equal(t, "homeserver 3", c.Name)
	assert.Equal(t, "homeserver", pair(other.ID, "homeserver").Name, "another account's machines don't count")

	require.NoError(t, s.RevokeDevice(ctx, a.ID, t0))
	assert.Equal(t, "homeserver", pair(u.ID, "homeserver").Name, "a removed machine's name is free")

	// Renaming follows the same rule, and keeps a name the machine already has.
	kept, err := s.RenameDevice(ctx, c.ID, "HomeServer 2")
	require.NoError(t, err)
	assert.Equal(t, "HomeServer 2 2", kept)
	kept, err = s.RenameDevice(ctx, b.ID, "HomeServer 2")
	require.NoError(t, err)
	assert.Equal(t, "HomeServer 2", kept)
	kept, err = s.RenameDevice(ctx, b.ID, "nas")
	require.NoError(t, err)
	assert.Equal(t, "nas", kept)
	got, err := s.Device(ctx, b.ID)
	require.NoError(t, err)
	assert.Equal(t, "nas", got.Name)
	_, err = s.RenameDevice(ctx, "dev_missing", "x")
	require.ErrorIs(t, err, store.ErrNotFound)
}

func TestDevicePairing(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	dc, uc := []byte("device-code-hash"), []byte("user-code-hash")
	p := store.DevicePairing{Name: "homeserver", Kind: store.KindLinux, PublicKey: []byte("pkix"), CreatedAt: t0, ExpiresAt: t0.Add(10 * time.Minute)}
	require.NoError(t, s.CreateDevicePairing(ctx, dc, uc, p))
	require.ErrorIs(t, s.CreateDevicePairing(ctx, []byte("other"), uc, p), store.ErrConflict, "user codes are unique")

	_, last, err := s.PollDevicePairing(ctx, dc, t0.Add(5*time.Second))
	require.ErrorIs(t, err, store.ErrPairingPending)
	assert.True(t, last.IsZero(), "first poll")
	_, last, err = s.PollDevicePairing(ctx, dc, t0.Add(10*time.Second))
	require.ErrorIs(t, err, store.ErrPairingPending)
	assert.Equal(t, t0.Add(5*time.Second), last)

	got, err := s.DevicePairingByUserCode(ctx, uc, t0.Add(time.Minute))
	require.NoError(t, err)
	assert.Equal(t, "homeserver", got.Name)
	assert.Equal(t, store.KindLinux, got.Kind)
	_, err = s.DevicePairingByUserCode(ctx, []byte("wrong"), t0.Add(time.Minute))
	require.ErrorIs(t, err, store.ErrNotFound)

	d, err := s.ApproveDevicePairing(ctx, uc, u.ID, t0.Add(time.Minute))
	require.NoError(t, err)
	assert.Equal(t, "homeserver", d.Name)
	assert.Equal(t, store.KindLinux, d.Kind)
	assert.Equal(t, []byte("pkix"), d.PublicKey)
	_, err = s.ApproveDevicePairing(ctx, uc, u.ID, t0.Add(time.Minute))
	require.ErrorIs(t, err, store.ErrNotFound, "approved once")
	_, err = s.DevicePairingByUserCode(ctx, uc, t0.Add(time.Minute))
	require.ErrorIs(t, err, store.ErrNotFound, "no longer offered for approval")

	collected, _, err := s.PollDevicePairing(ctx, dc, t0.Add(70*time.Second))
	require.NoError(t, err)
	assert.Equal(t, d.ID, collected.ID)
	_, _, err = s.PollDevicePairing(ctx, dc, t0.Add(75*time.Second))
	require.ErrorIs(t, err, store.ErrPairingExpired, "collected once")

	// An unapproved request expires; an unknown one is expired.
	require.NoError(t, s.CreateDevicePairing(ctx, []byte("dc2"), []byte("uc2"), p))
	_, _, err = s.PollDevicePairing(ctx, []byte("dc2"), t0.Add(10*time.Minute))
	require.ErrorIs(t, err, store.ErrPairingExpired)
	_, err = s.ApproveDevicePairing(ctx, []byte("uc2"), u.ID, t0.Add(10*time.Minute))
	require.ErrorIs(t, err, store.ErrNotFound)
	_, _, err = s.PollDevicePairing(ctx, []byte("nope"), t0)
	require.ErrorIs(t, err, store.ErrPairingExpired)

	// Purged an hour after expiry.
	require.NoError(t, s.PurgeDevicePairings(ctx, t0.Add(70*time.Minute)))
	_, _, err = s.PollDevicePairing(ctx, dc, t0)
	require.ErrorIs(t, err, store.ErrPairingExpired)
}

func TestDeviceState(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	d := newDevice(t, s, u.ID)

	_, err := s.DeviceState(ctx, d.ID)
	require.ErrorIs(t, err, store.ErrNotFound)

	online := store.DeviceState{
		DeviceID:    d.ID,
		Online:      true,
		ConnectedAt: t0,
		LastSeenAt:  t0.Add(15 * time.Second),
		StateJSON:   []byte(`{"battery_percent":82}`),
		ToolsJSON:   []byte(`[]`),
	}
	require.NoError(t, s.PutDeviceState(ctx, online))
	got, err := s.DeviceState(ctx, d.ID)
	require.NoError(t, err)
	assert.Equal(t, online, got)

	offline := online
	offline.Online = false
	offline.OfflineReason = "low_battery"
	offline.LastSeenAt = t0.Add(time.Minute)
	require.NoError(t, s.PutDeviceState(ctx, offline))
	got, err = s.DeviceState(ctx, d.ID)
	require.NoError(t, err)
	assert.Equal(t, offline, got)

	// The status alone: everything but the tool list.
	status := offline
	status.Online, status.OfflineReason, status.StateJSON = true, "", []byte(`{"battery_percent":80}`)
	status.ToolsJSON = []byte(`["not written"]`)
	require.NoError(t, s.PutDeviceStatus(ctx, status))
	got, err = s.DeviceState(ctx, d.ID)
	require.NoError(t, err)
	status.ToolsJSON = offline.ToolsJSON
	assert.Equal(t, status, got)
	require.ErrorIs(t, s.PutDeviceStatus(ctx, store.DeviceState{DeviceID: "dev_without_a_row"}), store.ErrNotFound)
}

func TestAuditLog(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	d := newDevice(t, s, u.ID)

	old := store.AuditEntry{
		UserID: u.ID, DeviceID: d.ID, At: t0, Tool: "battery_status",
		Surface: "claude-ai", Outcome: store.OutcomeOK, Duration: 420 * time.Millisecond,
		CallID: "call_7Q2MXK4RZB3N8P5TVWYC6DHJ9F",
	}
	recent := old
	recent.CallID = "call_0000000000000000000000000A"
	recent.At = t0.Add(31 * 24 * time.Hour)
	recent.Outcome = store.OutcomeOffline
	recent.Duration = 3 * time.Millisecond
	require.NoError(t, s.AddAudit(ctx, old))
	require.NoError(t, s.AddAudit(ctx, recent))

	bad := old
	bad.Outcome = "maybe"
	require.Error(t, s.AddAudit(ctx, bad))

	entries, err := s.AuditForUser(ctx, u.ID, 10)
	require.NoError(t, err)
	require.Len(t, entries, 2)
	assert.Equal(t, recent.At, entries[0].At, "newest first")
	assert.Equal(t, store.OutcomeOffline, entries[0].Outcome)
	assert.Equal(t, old.Duration, entries[1].Duration)
}

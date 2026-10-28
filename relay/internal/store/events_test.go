package store_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

func TestEventsAreKeptWithTheirAccount(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	d := newDevice(t, s, u.ID)

	e := store.Event{At: t0, Kind: "mac_connected", UserID: u.ID, DeviceID: d.ID, Detail: "app 0.9.0"}
	require.NoError(t, s.AddEvent(ctx, e))
	require.NoError(t, s.AddEvent(ctx, store.Event{At: t0.Add(time.Second), Kind: "mac_disconnected", UserID: u.ID, DeviceID: d.ID}))
	require.NoError(t, s.AddEvent(ctx, store.Event{At: t0, Kind: "request_refused", Detail: "no account"}))

	got, err := s.Events(ctx, u.ID, 10)
	require.NoError(t, err)
	require.Len(t, got, 2)
	assert.Equal(t, "mac_disconnected", got[0].Kind, "newest first")
	assert.Equal(t, e.Detail, got[1].Detail)
	assert.Equal(t, d.ID, got[1].DeviceID)
	assert.Equal(t, 1, got[1].Count)
	assert.Equal(t, t0, got[1].At)

	// Deleting the account deletes its events (FR-630: "until the account is deleted"); events
	// without an account stay.
	require.NoError(t, s.DeleteUser(ctx, u.ID))
	got, err = s.Events(ctx, u.ID, 10)
	require.NoError(t, err)
	assert.Empty(t, got)
	got, err = s.Events(ctx, "", 10)
	require.NoError(t, err)
	assert.Len(t, got, 1)
}

// Refusals are counted per hour: however many requests a stranger sends, one row per kind and
// reason and hour.
func TestCountedEventsMakeOneRowPerHour(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	hour := t0.Truncate(time.Hour)
	for i := range 500 {
		first, err := s.CountEvent(ctx, store.Event{At: hour.Add(time.Duration(i) * time.Second), Kind: "request_refused", Detail: "rate limit"})
		require.NoError(t, err)
		assert.Equal(t, i == 0, first)
	}
	first, err := s.CountEvent(ctx, store.Event{At: hour.Add(time.Second), Kind: "request_refused", Detail: "malformed request"})
	require.NoError(t, err)
	assert.True(t, first, "another reason is another row")
	first, err = s.CountEvent(ctx, store.Event{At: hour.Add(time.Hour), Kind: "request_refused", Detail: "rate limit"})
	require.NoError(t, err)
	assert.True(t, first, "the next hour is another row")

	got, err := s.Events(ctx, "", 10)
	require.NoError(t, err)
	require.Len(t, got, 3)
	byKey := map[string]store.Event{}
	for _, e := range got {
		byKey[fmt.Sprint(e.At.Truncate(time.Hour).Unix(), e.Detail)] = e
	}
	rl := byKey[fmt.Sprint(hour.Unix(), "rate limit")]
	assert.Equal(t, 500, rl.Count)
	assert.Equal(t, hour, rl.At, "the first of the hour")
	assert.Equal(t, hour.Add(499*time.Second), rl.LastAt, "and the last")

	// An account's refusals are counted separately from a stranger's.
	u := newUser(t, s)
	first, err = s.CountEvent(ctx, store.Event{At: hour, Kind: "request_refused", UserID: u.ID, Detail: "rate limit"})
	require.NoError(t, err)
	assert.True(t, first)
	mine, err := s.Events(ctx, u.ID, 10)
	require.NoError(t, err)
	require.Len(t, mine, 1)
	assert.Equal(t, 1, mine[0].Count)
}

// The audit of one Mac, page by page (FR-634): oldest first, from since on, never splitting the
// calls of one millisecond between pages.
func TestAuditForDevice(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	u := newUser(t, s)
	d := newDevice(t, s, u.ID)
	other, err := s.CreateUser(ctx, "b@example.com", t0)
	require.NoError(t, err)
	od := newDevice(t, s, other.ID)

	add := func(dev store.Device, user string, at time.Time, id string) {
		require.NoError(t, s.AddAudit(ctx, store.AuditEntry{
			UserID: user, DeviceID: dev.ID, At: at, Tool: "shell_run", Outcome: store.OutcomeOK,
			Duration: 5 * time.Millisecond, CallID: id,
		}))
	}
	add(d, u.ID, t0, "")                                  // from before call ids
	add(d, u.ID, t0.Add(time.Millisecond), "call_A")      // two in one millisecond
	add(d, u.ID, t0.Add(time.Millisecond), "call_B")      //
	add(d, u.ID, t0.Add(2*time.Millisecond), "call_C")    //
	add(od, other.ID, t0.Add(time.Millisecond), "call_X") // another Mac's
	add(d, u.ID, t0.Add(-time.Hour), "call_old")          // before since

	since := t0.UnixMilli()
	page, next, err := s.AuditForDevice(ctx, d.ID, since, 2)
	require.NoError(t, err)
	require.Len(t, page, 1, "the second row's millisecond continues on the next page")
	assert.Empty(t, page[0].CallID)
	require.NotNil(t, next)
	assert.Equal(t, t0.Add(time.Millisecond).UnixMilli(), *next)

	page, next, err = s.AuditForDevice(ctx, d.ID, *next, 2)
	require.NoError(t, err)
	require.Len(t, page, 2)
	assert.Equal(t, []string{"call_A", "call_B"}, []string{page[0].CallID, page[1].CallID})
	require.NotNil(t, next)

	page, next, err = s.AuditForDevice(ctx, d.ID, *next, 2)
	require.NoError(t, err)
	require.Len(t, page, 1)
	assert.Equal(t, "call_C", page[0].CallID)
	assert.Nil(t, next, "no more")

	all, next, err := s.AuditForDevice(ctx, d.ID, since, 1000)
	require.NoError(t, err)
	assert.Len(t, all, 4)
	assert.Nil(t, next)
}

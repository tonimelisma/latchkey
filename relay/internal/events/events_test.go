package events_test

import (
	"bytes"
	"context"
	"log/slog"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/events"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

func TestRecordStoresAndLogs(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(ctx, filepath.Join(t.TempDir(), "relay.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = st.Close() })
	u, err := st.CreateUser(ctx, "a@example.com", time.Now())
	require.NoError(t, err)
	var out bytes.Buffer
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	r := events.New(st, slog.New(slog.NewTextHandler(&out, nil)), func() time.Time { return now })

	r.Record(ctx, store.Event{Kind: events.MacConnected, UserID: u.ID, DeviceID: "dev_1", Detail: "app 0.9.0"})
	got, err := st.Events(ctx, u.ID, 10)
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, now, got[0].At)
	line := out.String()
	assert.Contains(t, line, `msg="Mac connected"`)
	assert.Contains(t, line, "event=mac_connected")
	assert.Contains(t, line, "user="+u.ID)
	assert.Contains(t, line, "device=dev_1")
	assert.Contains(t, line, `detail="app 0.9.0"`)

	// Counted events log the first of each hour only.
	out.Reset()
	for range 50 {
		r.Count(ctx, store.Event{Kind: events.RequestRefused, Detail: "POST /token: rate limit"})
	}
	assert.Equal(t, 1, strings.Count(out.String(), "event=request_refused"), out.String())
	got, err = st.Events(ctx, "", 10)
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, 50, got[0].Count)

	// Every kind has words for its log line.
	for _, k := range events.Kinds {
		assert.NotEqual(t, k, events.Title(k), k)
	}

	// A recorder that isn't set records nothing and doesn't fail.
	var none *events.Recorder
	none.Record(ctx, store.Event{Kind: events.MacConnected})
	none.Count(ctx, store.Event{Kind: events.RequestRefused})
}

// FR-683: the account's events also go to its trace; counted ones as often as they are logged
// (the first of each hour), so nobody can grow a trace without bound.
func TestEventsGoToTheTrace(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(ctx, filepath.Join(t.TempDir(), "relay.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = st.Close() })
	u, err := st.CreateUser(ctx, "a@example.com", time.Now())
	require.NoError(t, err)
	r := events.New(st, slog.New(slog.NewTextHandler(&bytes.Buffer{}, nil)), nil)
	var traced []store.Event
	r.TraceTo(func(e store.Event) { traced = append(traced, e) })
	r.Record(ctx, store.Event{Kind: events.MacConnected, UserID: u.ID, Detail: "app 0.9.0"})
	for range 5 {
		r.Count(ctx, store.Event{Kind: events.RequestRefused, UserID: u.ID, Detail: "POST /token: rate limit"})
	}
	r.Log(store.Event{Kind: events.AccountDeleted, UserID: u.ID})
	require.Len(t, traced, 2)
	assert.Equal(t, events.MacConnected, traced[0].Kind)
	assert.False(t, traced[0].At.IsZero(), "with its time")
	assert.Equal(t, events.RequestRefused, traced[1].Kind)

	var none *events.Recorder
	none.TraceTo(func(store.Event) {})
}

func TestTraceEventKinds(t *testing.T) {
	assert.Contains(t, events.Kinds, events.TracesPaused)
	assert.Contains(t, events.Kinds, events.TracesResumed)
	assert.Equal(t, "traces_paused", events.TracesPaused)
	assert.Equal(t, "traces_resumed", events.TracesResumed)
}

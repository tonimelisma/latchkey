package store_test

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Spec 014 FR-1403, FR-1412, FR-1414: the outbox gives due reports oldest first, retries later,
// forgets delivered ones, drops one account's, and goes with the account; the reporter tag is
// stable per account and differs between accounts.
func TestReportOutbox(t *testing.T) {
	ctx := context.Background()
	s, err := store.Open(ctx, filepath.Join(t.TempDir(), "relay.db"))
	require.NoError(t, err)
	defer func() { _ = s.Close() }()
	a, err := s.CreateUser(ctx, "a@example.com", t0)
	require.NoError(t, err)
	b, err := s.CreateUser(ctx, "b@example.com", t0)
	require.NoError(t, err)

	for i, r := range []store.OutboxReport{
		{ID: "r2", UserID: a.ID, Created: t0.Add(time.Second), Sealed: []byte("LKR1 second")},
		{ID: "r1", UserID: a.ID, Created: t0, Sealed: []byte("LKR1 first")},
		{ID: "r3", UserID: b.ID, Created: t0, Sealed: []byte("LKR1 b's")},
	} {
		require.NoError(t, s.AddReport(ctx, r), i)
	}
	due, err := s.DueReports(ctx, t0.Add(time.Minute), 10)
	require.NoError(t, err)
	require.Len(t, due, 3)
	assert.Equal(t, "r1", due[0].ID)
	assert.Equal(t, []byte("LKR1 first"), due[0].Sealed)

	require.NoError(t, s.ReportRetry(ctx, "r1", t0.Add(time.Hour)))
	due, err = s.DueReports(ctx, t0.Add(time.Minute), 10)
	require.NoError(t, err)
	assert.Len(t, due, 2, "r1 waits until its next try")

	require.NoError(t, s.ReportDone(ctx, "r2"))
	n, err := s.DropUserReports(ctx, a.ID)
	require.NoError(t, err)
	assert.EqualValues(t, 1, n, "only r1 of a's was left")
	due, err = s.DueReports(ctx, t0.Add(2*time.Hour), 10)
	require.NoError(t, err)
	require.Len(t, due, 1)
	assert.Equal(t, "r3", due[0].ID, "b's report untouched")

	require.NoError(t, s.DeleteUser(ctx, b.ID))
	due, err = s.DueReports(ctx, t0.Add(2*time.Hour), 10)
	require.NoError(t, err)
	assert.Empty(t, due, "goes with the account")

	ta, err := s.ReporterTag(a.ID)
	require.NoError(t, err)
	ta2, _ := s.ReporterTag(a.ID)
	tb, _ := s.ReporterTag(b.ID)
	assert.Equal(t, ta, ta2)
	assert.NotEqual(t, ta, tb)
	assert.Len(t, ta, 16)
	assert.NotContains(t, ta, a.ID)
}

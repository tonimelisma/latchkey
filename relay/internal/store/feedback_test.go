package store_test

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	_ "modernc.org/sqlite"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// FR-691, FR-692: reports are kept sealed, listed until a Mac saves them, per account, and go
// with the account.
func TestFeedbackIsKeptSealedUntilSavedAndGoesWithTheAccount(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "relay.db")
	s, err := store.Open(ctx, path)
	require.NoError(t, err)
	defer func() { _ = s.Close() }()
	a, err := s.CreateUser(ctx, "a@example.com", t0)
	require.NoError(t, err)
	b, err := s.CreateUser(ctx, "b@example.com", t0)
	require.NoError(t, err)

	secret := "the click on Create filter did nothing"
	first := store.Feedback{ID: "fb_00000000000000000000000001", UserID: a.ID, At: t0, Client: "Claude Code", Machine: "Mac", Summary: "Gmail", Details: secret}
	second := store.Feedback{ID: "fb_00000000000000000000000002", UserID: a.ID, At: t0.Add(1e9), Summary: "second"}
	other := store.Feedback{ID: "fb_00000000000000000000000003", UserID: b.ID, At: t0, Summary: "someone else's"}
	for _, f := range []store.Feedback{second, first, other} {
		require.NoError(t, s.AddFeedback(ctx, f))
	}

	waiting, err := s.WaitingFeedback(ctx, a.ID, 50)
	require.NoError(t, err)
	require.Len(t, waiting, 2)
	assert.Equal(t, first, waiting[0], "oldest first, all fields back")
	assert.Equal(t, second.ID, waiting[1].ID)

	// The text is sealed: it isn't in the database file as written.
	raw, err := sql.Open("sqlite", "file:"+path)
	require.NoError(t, err)
	var sealed []byte
	require.NoError(t, raw.QueryRowContext(ctx, `SELECT sealed FROM feedback WHERE id = ?`, first.ID).Scan(&sealed))
	_ = raw.Close()
	assert.NotContains(t, string(sealed), secret)
	assert.NotContains(t, string(sealed), "Claude Code")

	// Another account's ids are left alone; saved reports aren't listed again.
	require.NoError(t, s.FeedbackDelivered(ctx, a.ID, []string{first.ID, other.ID}, t0))
	waiting, err = s.WaitingFeedback(ctx, a.ID, 50)
	require.NoError(t, err)
	require.Len(t, waiting, 1)
	assert.Equal(t, second.ID, waiting[0].ID)
	theirs, err := s.WaitingFeedback(ctx, b.ID, 50)
	require.NoError(t, err)
	assert.Len(t, theirs, 1)

	require.NoError(t, s.DeleteUser(ctx, a.ID))
	waiting, err = s.WaitingFeedback(ctx, a.ID, 50)
	require.NoError(t, err)
	assert.Empty(t, waiting)
}

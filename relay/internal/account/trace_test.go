package account_test

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/account"
	"github.com/tonimelisma/latchkey/relay/internal/trace"
)

func setupTraces(t *testing.T) (*env, *trace.Store) {
	t.Helper()
	ts, err := trace.New(trace.Options{
		Dir: filepath.Join(t.TempDir(), "traces"), Key: bytes.Repeat([]byte{3}, 32),
		FreeSpace: func(string) (uint64, error) { return 100 << 30, nil },
	})
	require.NoError(t, err)
	return setupWith(t, func(c *account.Config) { c.Traces = ts }), ts
}

// FR-685: the signed-in account downloads its own whole trace from the account page; nobody
// else's, and nothing without signing in.
func TestDownloadFullActivity(t *testing.T) {
	e, ts := setupTraces(t)
	b := e.browser()
	b.signUp()
	u, err := e.store.UserByEmail(context.Background(), "owner@example.com")
	require.NoError(t, err)
	other, err := e.store.CreateUser(context.Background(), "zed@example.com", time.Now())
	require.NoError(t, err)
	at := time.Date(2026, 11, 15, 8, 0, 0, 0, time.UTC)
	ts.Append(u.ID, at, trace.Line{
		Kind: trace.KindAction, Tool: "computer_look", Arguments: json.RawMessage(`{}`), Outcome: "ok", CallID: "call_1",
		Result: json.RawMessage(`[{"type":"image","mimeType":"image/png","data":"iVBORw0KGgo="}]`),
	})
	ts.Append(u.ID, at.Add(time.Hour), trace.Event("sign_in_passkey", "signed in", ""))
	ts.Append(other.ID, at, trace.Event("mac_connected", "someone else's", ""))

	page := b.get("/account")
	require.Equal(t, http.StatusOK, page.status)
	assert.Contains(t, page.body, `href="/account/trace"`)
	assert.Contains(t, page.body, "Download full activity")
	activity := b.get("/account/activity")
	assert.Contains(t, activity.body, `href="/account/trace"`, "the activity page points at it too")
	assert.NotContains(t, activity.body, "never stored")

	r := b.get("/account/trace")
	require.Equal(t, http.StatusOK, r.status, r.body)
	assert.Equal(t, "application/x-ndjson; charset=utf-8", r.header.Get("Content-Type"))
	assert.Equal(t, `attachment; filename="latchkey-trace-`+e.clock.now().UTC().Format("2006-01-02")+`.jsonl"`, r.header.Get("Content-Disposition"))
	assert.Equal(t, "no-store", r.header.Get("Cache-Control"))
	assert.Equal(t, "nosniff", r.header.Get("X-Content-Type-Options"))
	lines := strings.Split(strings.TrimSuffix(r.body, "\n"), "\n")
	require.Len(t, lines, 2)
	assert.JSONEq(t, `{"v":1,"source":"relay","machine":null,"time":"2026-11-15T08:00:00.000Z","kind":"action",
		"tool":"computer_look","arguments":{},"result":[{"type":"image","mimeType":"image/png","data":"iVBORw0KGgo="}],
		"isError":false,"durationMS":0,"call_id":"call_1","client":null,"outcome":"ok","account":"owner@example.com"}`, lines[0])
	assert.Contains(t, lines[1], `"tool":"sign_in_passkey"`)
	assert.NotContains(t, r.body, "someone else's")

	stranger := e.browser()
	r = stranger.get("/account/trace")
	assert.Equal(t, http.StatusFound, r.status, "sign in first")
	assert.NotContains(t, r.body, "computer_look")
}

// A relay without traces offers no download.
func TestNoDownloadWithoutTraces(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.signUp()
	assert.NotContains(t, b.get("/account").body, "/account/trace")
	assert.NotContains(t, b.get("/account/activity").body, "/account/trace")
	assert.Equal(t, http.StatusNotFound, b.get("/account/trace").status)
}

// FR-687: the account's own Delete account removes its traces.
func TestDeleteAccountRemovesTraces(t *testing.T) {
	e, ts := setupTraces(t)
	b := e.browser()
	b.signUp()
	u, err := e.store.UserByEmail(context.Background(), "owner@example.com")
	require.NoError(t, err)
	ts.Append(u.ID, time.Now(), trace.Event("sign_in_passkey", "signed in", ""))
	dir := filepath.Join(ts.Dir(), u.ID)
	_, err = os.Stat(dir)
	require.NoError(t, err)

	token := csrf(t, b.get("/account").body)
	status, _ := b.signIn("reauth", nil)
	require.Equal(t, http.StatusOK, status)
	r := b.form("/account/delete", url.Values{"csrf": {token}})
	require.Equal(t, http.StatusOK, r.status, r.body)
	assert.NoDirExists(t, dir)
}

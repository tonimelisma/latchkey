package server

import (
	"bytes"
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/events"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

type logBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *logBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *logBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

func harnessWithLog(t *testing.T) (*harness, *logBuffer) {
	t.Helper()
	out := &logBuffer{}
	h := newHarness(t, func(o *Options) { o.Logger = slog.New(slog.NewTextHandler(out, nil)) })
	return h, out
}

// event waits for an event of the kind whose detail contains detail, for the account (or, with
// userID "", without one), and returns it.
func (h *harness) event(userID, kind, detail string) store.Event {
	h.t.Helper()
	var found store.Event
	require.Eventually(h.t, func() bool {
		all, err := h.db.Events(context.Background(), userID, 1000)
		require.NoError(h.t, err)
		for _, e := range all {
			if e.Kind == kind && strings.Contains(e.Detail, detail) {
				found = e
				return true
			}
		}
		return false
	}, 5*time.Second, 10*time.Millisecond, "event %s %q", kind, detail)
	return found
}

// FR-630, FR-024, FR-636: the daily housekeeping deletes no audit entry and no event, however old.
func TestNothingIsDeletedByAge(t *testing.T) {
	h, _ := harnessWithLog(t)
	o := h.owner("owner@example.com")
	a := o.mac()
	ctx := context.Background()
	long := time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
	for i := range 3 {
		require.NoError(t, h.db.AddAudit(ctx, store.AuditEntry{
			UserID: o.user.ID, DeviceID: a.DeviceID, At: long.Add(time.Duration(i) * time.Hour), Tool: "shell_run",
			Outcome: store.OutcomeOK, CallID: agentproto.NewCallID(),
		}))
		require.NoError(t, h.db.AddEvent(ctx, store.Event{At: long, Kind: events.MacConnected, UserID: o.user.ID, DeviceID: a.DeviceID}))
		_, err := h.db.CountEvent(ctx, store.Event{At: long, Kind: events.RequestRefused, Detail: "x"})
		require.NoError(t, err)
	}
	for _, years := range []int{1, 5, 30} {
		h.relay.Daily(ctx, time.Now().AddDate(years, 0, 0), slog.New(slog.DiscardHandler))
	}
	audit, err := h.db.AuditForUser(ctx, o.user.ID, 100)
	require.NoError(t, err)
	assert.Len(t, audit, 3, "no audit entry is deleted by age")
	mine, err := h.db.Events(ctx, o.user.ID, 100)
	require.NoError(t, err)
	assert.Len(t, mine, 3, "no event is deleted by age")
	strangers, err := h.db.Events(ctx, "", 100)
	require.NoError(t, err)
	require.Len(t, strangers, 1)
	assert.Equal(t, 3, strangers[0].Count)

	// Deleting the account deletes both (FR-630: until the account is deleted).
	require.NoError(t, h.db.DeleteUser(ctx, o.user.ID))
	audit, err = h.db.AuditForUser(ctx, o.user.ID, 100)
	require.NoError(t, err)
	assert.Empty(t, audit)
	mine, err = h.db.Events(ctx, o.user.ID, 100)
	require.NoError(t, err)
	assert.Empty(t, mine)
}

// FR-631, FR-636: each Claude app approved, refused, or removed, whoever removed it.
func TestClaudeAppEventsAreRecorded(t *testing.T) {
	h, out := harnessWithLog(t)
	o := h.owner("owner@example.com")
	client := h.registerClient(claudeCallback)

	o.approve(client, claudeCallback)
	h.event(o.user.ID, events.ClaudeApproved, "Claude")
	assert.Contains(t, out.String(), `msg="Claude app approved"`)

	// Declined on the consent page.
	q := url.Values{
		"response_type": {"code"}, "client_id": {client}, "redirect_uri": {claudeCallback},
		"scope": {"mcp"}, "state": {"state-123456789"},
		"code_challenge": {"E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"}, "code_challenge_method": {"S256"},
	}
	path := "/authorize?" + q.Encode()
	r := o.form(path, url.Values{"csrf": {o.csrf(path)}, "decision": {"deny"}})
	require.Equal(t, http.StatusSeeOther, r.status, r.body)
	h.event(o.user.ID, events.ClaudeRefused, "Claude")

	// Removed on the account page, from the Mac app, all at once, and by expiry.
	grants, err := h.db.LiveGrants(context.Background(), o.user.ID, time.Now(), 50)
	require.NoError(t, err)
	require.Len(t, grants, 1)
	r = o.form("/account/revoke-client", url.Values{"csrf": {o.csrf("/account")}, "id": {grants[0].ID}})
	require.Equal(t, http.StatusSeeOther, r.status)
	h.event(o.user.ID, events.ClaudeRemoved, "on the account page")

	a := o.mac(agentproto.FeatureClients)
	c := h.dial(a)
	nextClients(t, c)
	o.approve(client, claudeCallback)
	list := nextClients(t, c)
	require.Len(t, list, 1)
	require.NoError(t, c.Send(tctx(t), &agentproto.RevokeClient{ID: list[0].ID}))
	h.event(o.user.ID, events.ClaudeRemoved, "from the Mac app")

	o.approve(client, claudeCallback)
	r = o.form("/account/revoke-claude", url.Values{"csrf": {o.csrf("/account")}})
	require.Equal(t, http.StatusSeeOther, r.status)
	require.Eventually(t, func() bool {
		all, err := h.db.Events(context.Background(), o.user.ID, 1000)
		require.NoError(t, err)
		n := 0
		for _, e := range all {
			if e.Kind == events.ClaudeRemoved && strings.HasSuffix(e.Detail, ", on the account page") {
				n++
			}
		}
		return n == 2
	}, 5*time.Second, 10*time.Millisecond, "removing every app is recorded for each")

	o.approve(client, claudeCallback)
	h.relay.Daily(context.Background(), time.Now().AddDate(1, 0, 0), slog.New(slog.DiscardHandler))
	h.event(o.user.ID, events.ClaudeRemoved, "its access expired")
	assert.Contains(t, out.String(), `msg="Claude app removed"`)
}

// FR-631, FR-636: refused requests are recorded with the reason, counted per hour, and a
// stranger's flood makes one row and one line.
func TestRefusedRequestsAreCounted(t *testing.T) {
	h, out := harnessWithLog(t)
	for range 20 {
		assert.Equal(t, http.StatusUnauthorized, h.mcpStatus("not-a-token"))
	}
	e := h.event("", events.RequestRefused, "/mcp: 401 token rejected")
	assert.Equal(t, 20, e.Count)
	assert.Equal(t, 1, strings.Count(out.String(), "token rejected"), "one line for the hour")

	r := h.do(nil, http.MethodPost, "/mcp", "application/json", `{}`, nil)
	assert.Equal(t, http.StatusUnauthorized, r.status)
	h.event("", events.RequestRefused, "/mcp: 401 no token")

	assert.Equal(t, http.StatusNotFound, h.get("/no-such-page-"+strings.Repeat("x", 50)).status)
	e = h.event("", events.RequestRefused, "no such page: 404 not found")
	assert.NotContains(t, e.Detail, "xxxx", "the path a client made up is not recorded")

	// An expired or revoked token of an Owner is refused too.
	o := h.owner("owner@example.com")
	access, _ := o.approve(h.registerClient(claudeCallback), claudeCallback)
	require.NoError(t, h.db.DeleteUserOAuth(context.Background(), o.user.ID))
	assert.Equal(t, http.StatusUnauthorized, h.mcpStatus(access))
	assert.Equal(t, 21, h.event("", events.RequestRefused, "/mcp: 401 token rejected").Count,
		"a token that no longer works names no account: it is counted with the strangers'")
	// The rate limit, by address.
	limited := false
	for range 30 {
		if h.do(nil, http.MethodPost, "/register", "application/json", `{}`, nil).status == http.StatusTooManyRequests {
			limited = true
			break
		}
	}
	require.True(t, limited)
	h.event("", events.RequestRefused, "POST /register: 429 rate limit per address")

	// A malformed request.
	r = h.do(nil, http.MethodPost, "/auth/email", "application/json", `{not json`, nil)
	assert.Equal(t, http.StatusBadRequest, r.status)
	h.event("", events.RequestRefused, "POST /auth/email: 400")

	assert.NotContains(t, out.String(), access, "no token in the output")
	assert.NotContains(t, out.String(), "not-a-token")
}

// FR-631: a request the relay failed is recorded as failed, with its route.
func TestFailedRequestsAreCounted(t *testing.T) {
	ctx := context.Background()
	db, err := store.Open(ctx, t.TempDir()+"/relay.db")
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	out := &logBuffer{}
	rec := events.New(db, slog.New(slog.NewTextHandler(out, nil)), nil)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /broken", func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "Something went wrong.", http.StatusInternalServerError)
	})
	srv := httptest.NewServer(guard(nil, nil, rec, mux))
	t.Cleanup(srv.Close)
	resp, err := http.Get(srv.URL + "/broken") //nolint:noctx // a test against a local server
	require.NoError(t, err)
	_ = resp.Body.Close()
	got, err := db.Events(ctx, "", 10)
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, events.RequestFailed, got[0].Kind)
	assert.Equal(t, "GET /broken: 500 internal error", got[0].Detail)
	assert.Contains(t, out.String(), `msg="request failed"`)
}

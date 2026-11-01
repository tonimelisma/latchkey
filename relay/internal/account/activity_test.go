package account_test

import (
	"context"
	"net/http"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/events"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

var olderRE = regexp.MustCompile(`href="(/account/activity\?before=\d+)"`)

func entries(body string) int { return strings.Count(body, `<li class="entry`) }

// FR-651, FR-654, FR-655: the account page shows the last 10 entries, a link to the rest, how to
// add a machine with this relay's install line, and the connector address.
func TestAccountPageParts(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.signUp()
	ctx := context.Background()
	u, _ := e.store.UserByEmail(ctx, "owner@example.com")
	start := e.clock.now().Add(-time.Hour)
	for i := range 15 {
		require.NoError(t, e.store.AddAudit(ctx, store.AuditEntry{UserID: u.ID, At: start.Add(time.Duration(i) * time.Minute), Tool: "shell_run", Outcome: "ok"}))
	}

	page := b.get("/account")
	require.Equal(t, http.StatusOK, page.status)
	assert.Equal(t, 10, entries(page.body), "the last 10 only")
	assert.Contains(t, page.body, `href="/account/activity"`)
	assert.Contains(t, page.body, "Add a machine")
	assert.Contains(t, strings.ReplaceAll(page.body, "<wbr>", ""), "linux/install.sh | sh -s -- "+e.base)
	assert.Contains(t, strings.ReplaceAll(page.body, "<wbr>", ""), e.base+"/mcp", "the connector address, even with no Claude app yet")
	assert.Contains(t, page.body, "data-copy", "copy buttons")
	for _, part := range []string{"Machines", "Add a machine", "Claude", "Recent activity", "Account"} {
		assert.Contains(t, page.body, ">"+part+"</h2>")
	}
}

// FR-652, FR-653, FR-657: tool calls and the Owner's account events in one list, newest first, 50
// at a time, back to the first; operator-only events and other accounts stay out.
func TestActivityPage(t *testing.T) {
	e := setup(t)
	b := e.browser()
	assert.Equal(t, http.StatusFound, b.get("/account/activity").status, "sign in first")
	b.signUp()
	ctx := context.Background()
	u, _ := e.store.UserByEmail(ctx, "owner@example.com")
	other, err := e.store.CreateUser(ctx, "other@example.com", e.clock.now())
	require.NoError(t, err)
	d, err := e.store.CreateDevice(ctx, store.NewDevice{UserID: u.ID, Name: "purkki", Kind: store.KindLinux, PublicKey: []byte("k")}, e.clock.now())
	require.NoError(t, err)

	start := e.clock.now().Add(-24 * time.Hour)
	for i := range 110 {
		require.NoError(t, e.store.AddAudit(ctx, store.AuditEntry{UserID: u.ID, DeviceID: d.ID, At: start.Add(time.Duration(i) * time.Minute), Tool: "files_read", Outcome: "ok", Surface: "claude-code"}))
	}
	// Two entries in the same millisecond as a page's last entry are never split or skipped.
	same := start.Add(59 * time.Minute)
	require.NoError(t, e.store.AddAudit(ctx, store.AuditEntry{UserID: u.ID, At: same, Tool: "shell_check", Outcome: "error"}))
	require.NoError(t, e.store.AddEvent(ctx, store.Event{At: start.Add(30 * time.Second), Kind: events.MacPaired, UserID: u.ID, DeviceID: d.ID, Detail: "a Linux server"}))
	require.NoError(t, e.store.AddEvent(ctx, store.Event{At: start.Add(90 * time.Minute), Kind: events.SignInPasskey, UserID: u.ID, Detail: "signed in"}))
	require.NoError(t, e.store.AddEvent(ctx, store.Event{At: start.Add(91 * time.Minute), Kind: events.MacConnected, UserID: u.ID, DeviceID: d.ID, Detail: "operator only"}))
	require.NoError(t, e.store.AddAudit(ctx, store.AuditEntry{UserID: other.ID, At: start, Tool: "theirs_tool", Outcome: "ok"}))

	var all []string
	next := "/account/activity"
	for pages := 0; next != ""; pages++ {
		require.Less(t, pages, 5)
		p := b.get(next)
		require.Equal(t, http.StatusOK, p.status)
		all = append(all, p.body)
		next = ""
		if m := olderRE.FindStringSubmatch(p.body); m != nil {
			next = m[1]
		}
	}
	require.Len(t, all, 3, "113 entries make three pages")
	assert.Equal(t, 50, entries(all[0]))
	total := 0
	for _, p := range all {
		total += entries(p)
	}
	assert.Equal(t, 113, total, "every entry exactly once")
	joined := strings.Join(all, "")
	assert.Contains(t, joined, "Machine connected")
	assert.Contains(t, joined, "Signed in with a passkey")
	assert.Contains(t, joined, "shell_check")
	assert.Contains(t, joined, "purkki")
	assert.Contains(t, joined, `<time datetime="`)
	assert.NotContains(t, joined, "operator only")
	assert.NotContains(t, joined, "theirs_tool")
	assert.Less(t, strings.Index(joined, "Signed in with a passkey"), strings.Index(joined, "shell_check"), "newest first")
	assert.Less(t, strings.Index(joined, "shell_check"), strings.Index(joined, "Machine connected"), "newest first")
}

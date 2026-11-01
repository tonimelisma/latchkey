package server

import (
	"net/http"
	"net/url"
	"regexp"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/mcpserver"
	"github.com/tonimelisma/latchkey/relay/internal/oauth"
)

func TestGrantKeyIsSharedByTheBearerCheckAndTheMCPLayer(t *testing.T) {
	assert.Equal(t, oauth.GrantExtra, mcpserver.GrantExtra)
}

func ended(ch <-chan struct{}, within time.Duration) bool {
	select {
	case <-ch:
		return true
	case <-time.After(within):
		return false
	}
}

// The Mac app sees which Claude apps have access and removes one (FR-190, FR-191): the list
// arrives after welcome and after each approval; revoke_client ends exactly that approval, at
// once, on /mcp and in its open session, while the other approval of the same client and another
// account's approval go on working.
func TestMacSeesAppsWithAccessAndRemovesOne(t *testing.T) {
	h := newHarness(t, nil)
	o := h.owner("owner@example.com")
	mac := h.dial(o.mac(agentproto.FeatureClients))
	list := nextClients(t, mac)
	assert.NotNil(t, list)
	assert.Empty(t, list, "right after welcome: nothing has access yet")

	client := h.registerClient(claudeCallback, "http://localhost:7777/callback")
	access1, _ := o.approve(client, claudeCallback)
	list = nextClients(t, mac)
	require.Len(t, list, 1, "sent again on a new approval")
	assert.Equal(t, "Claude", list[0].Name)
	assert.Equal(t, "claude.ai", list[0].Host)
	assert.Equal(t, "claude.ai", list[0].Redirect)
	assert.WithinDuration(t, time.Now(), list[0].ApprovedAt, time.Minute)
	assert.Nil(t, list[0].LastUsedAt)
	assert.Regexp(t, `^[A-Za-z0-9_-]{1,64}$`, list[0].ID)
	first := list[0].ID

	time.Sleep(5 * time.Millisecond) // approvals are ordered by time, in milliseconds
	access2, _ := o.approve(client, "http://localhost:51515/callback")
	list = nextClients(t, mac)
	require.Len(t, list, 2, "the same client approved twice is two entries")
	assert.Equal(t, "this computer", list[0].Redirect, "newest first")
	assert.Equal(t, first, list[1].ID, "an entry's ID is stable")
	second := list[0].ID

	// Another account, with its own Mac and its own approval of the same client.
	other := h.owner("other@example.com")
	otherMac := h.dial(other.mac(agentproto.FeatureClients))
	assert.Empty(t, nextClients(t, otherMac))
	otherAccess, _ := other.approve(client, claudeCallback)
	theirs := nextClients(t, otherMac)
	require.Len(t, theirs, 1)
	noClients(t, mac)

	// Open sessions of both of the Owner's approvals.
	stream1 := h.mcpStream(access1, h.mcpSession(access1))
	stream2 := h.mcpStream(access2, h.mcpSession(access2))
	assert.False(t, ended(stream1, 200*time.Millisecond))

	// The ID of another account's approval does nothing, and is answered with the same list.
	require.NoError(t, mac.Send(tctx(t), &agentproto.RevokeClient{ID: theirs[0].ID}))
	assert.Len(t, nextClients(t, mac), 2)
	assert.Equal(t, http.StatusOK, h.mcpStatus(otherAccess))
	noClients(t, otherMac)

	// The right ID removes exactly that approval.
	require.NoError(t, mac.Send(tctx(t), &agentproto.RevokeClient{ID: first}))
	list = nextClients(t, mac)
	require.Len(t, list, 1)
	assert.Equal(t, second, list[0].ID)
	assert.Equal(t, http.StatusUnauthorized, h.mcpStatus(access1), "its access token stops working on /mcp")
	assert.Equal(t, http.StatusOK, h.mcpStatus(access2), "the other approval keeps working")
	assert.Equal(t, http.StatusOK, h.mcpStatus(otherAccess))
	assert.True(t, ended(stream1, 5*time.Second), "its open session is closed")
	assert.False(t, ended(stream2, 300*time.Millisecond), "the other approval's session is not disturbed")
	assert.True(t, h.relay.Hub.Online(mac.Agent().DeviceID))
}

var grantFormRE = regexp.MustCompile(`name="id" value="([^"]+)"`)

// The account page has the same per-app Remove, and still "Remove Claude's access" for all; the
// Mac's list follows both, and a client's own revocation too.
func TestAccountPageRemovesOneAppAndTheMacFollows(t *testing.T) {
	h := newHarness(t, nil)
	o := h.owner("owner@example.com")
	mac := h.dial(o.mac(agentproto.FeatureClients))
	nextClients(t, mac)
	client := h.registerClient(claudeCallback)
	access1, _ := o.approve(client, claudeCallback)
	nextClients(t, mac)
	time.Sleep(5 * time.Millisecond)
	access2, refresh2 := o.approve(client, claudeCallback)
	list := nextClients(t, mac)
	require.Len(t, list, 2)

	page := o.get("/account")
	ids := grantFormRE.FindAllStringSubmatch(page.body, -1)
	require.Len(t, ids, 2, "a Remove button per app")
	assert.Equal(t, list[0].ID, ids[0][1], "same order and IDs as the Mac's list")
	assert.Contains(t, page.body, "Claude (claude.ai)")
	assert.Contains(t, page.body, "Remove Claude")
	token := csrfRE.FindStringSubmatch(page.body)[1]

	// No CSRF token, no removal.
	r := o.form("/account/revoke-client", url.Values{"id": {list[1].ID}})
	assert.Equal(t, http.StatusForbidden, r.status)
	assert.Equal(t, http.StatusOK, h.mcpStatus(access1))

	r = o.form("/account/revoke-client", url.Values{"csrf": {token}, "id": {list[1].ID}})
	require.Equal(t, http.StatusSeeOther, r.status, r.body)
	assert.Equal(t, http.StatusUnauthorized, h.mcpStatus(access1))
	assert.Equal(t, http.StatusOK, h.mcpStatus(access2))
	after := nextClients(t, mac)
	require.Len(t, after, 1)
	assert.Equal(t, list[0].ID, after[0].ID)
	assert.Len(t, grantFormRE.FindAllStringSubmatch(o.get("/account").body, -1), 1)

	// Another account's signed-in browser can't remove it.
	other := h.owner("other@example.com")
	r = other.form("/account/revoke-client", url.Values{"csrf": {other.csrf("/account")}, "id": {list[0].ID}})
	assert.Equal(t, http.StatusSeeOther, r.status)
	assert.Equal(t, http.StatusOK, h.mcpStatus(access2))
	noClients(t, mac)

	// The client revokes its own token (RFC 7009): the Mac's list empties.
	rev := h.do(nil, http.MethodPost, "/revoke", "application/x-www-form-urlencoded",
		url.Values{"token": {refresh2}, "client_id": {client}}.Encode(), nil)
	require.Equal(t, http.StatusOK, rev.status)
	assert.Empty(t, nextClients(t, mac))
	assert.Equal(t, http.StatusUnauthorized, h.mcpStatus(access2))

	// "Remove Claude's access" still removes everything.
	access3, _ := o.approve(client, claudeCallback)
	require.Len(t, nextClients(t, mac), 1)
	r = o.form("/account/revoke-claude", url.Values{"csrf": {token}})
	require.Equal(t, http.StatusSeeOther, r.status)
	assert.Empty(t, nextClients(t, mac))
	assert.Equal(t, http.StatusUnauthorized, h.mcpStatus(access3))
}

// The app as installed today (0.8.9) announces no features and must never be sent a clients
// message, which it would take for a protocol violation.
func TestOldMacAppIsNeverSentTheList(t *testing.T) {
	h := newHarness(t, nil)
	o := h.owner("owner@example.com")
	a := o.mac()
	mac := h.dial(a)
	client := h.registerClient(claudeCallback)
	access, _ := o.approve(client, claudeCallback)
	require.Equal(t, http.StatusOK, h.mcpStatus(access))
	r := o.form("/account/revoke-claude", url.Values{"csrf": {o.csrf("/account")}})
	require.Equal(t, http.StatusSeeOther, r.status)
	noClients(t, mac)
	select {
	case n := <-mac.Notices:
		assert.Equal(t, agentproto.NoticeClientAuthorized, n.Kind, "it still gets the notice it knows")
	case <-time.After(3 * time.Second):
		t.Fatal("no notice")
	}
	assert.True(t, h.relay.Hub.Online(a.DeviceID))
}

package server

import (
	"bytes"
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/operator"
	"github.com/tonimelisma/latchkey/relay/internal/store"
	"github.com/tonimelisma/latchkey/relay/internal/testagent"
)

// command runs an operator command the way `docker exec … /relay <args>` does: another
// connection to the same database file, beside the running relay.
func (h *harness) command(args ...string) string {
	h.t.Helper()
	db, err := store.Open(context.Background(), h.dbPath)
	require.NoError(h.t, err)
	defer func() { _ = db.Close() }()
	var out bytes.Buffer
	require.NoError(h.t, operator.Run(context.Background(), operator.Env{Store: db, Out: &out, Actor: "test", Now: time.Now}, args))
	return out.String()
}

// watch starts the relay's follow-up of operator commands, polling fast.
func (h *harness) watch() {
	ctx, cancel := context.WithCancel(context.Background())
	h.t.Cleanup(cancel)
	go h.relay.WatchOperator(ctx, 50*time.Millisecond)
}

func closeCode(t *testing.T, c *testagent.Conn) int {
	t.Helper()
	code, err := c.Wait(tctx(t))
	require.NoError(t, err)
	return code
}

func TestOperatorPollFitsTheRequirement(t *testing.T) {
	assert.LessOrEqual(t, OperatorPoll, 2*time.Second, "FR-198 allows open connections 5 seconds")
}

// `account suspend` beside the running relay (FR-196, FR-198): the next request of every kind
// is refused at once, the Mac's live connection and Claude's open session are closed within the
// poll, the Mac keeps its pairing, and nothing is deleted. `account unsuspend` restores sign-in
// and the Mac's connection; Claude must be approved again.
func TestSuspendingAnAccountWhileTheRelayRuns(t *testing.T) {
	h := newHarness(t, withOperator(sampleOperator))
	h.watch()
	o := h.owner("owner@example.com")
	agent := o.mac(agentproto.FeatureClients)
	mac := h.dial(agent)
	client := h.registerClient(claudeCallback)
	access, refresh := o.approve(client, claudeCallback)
	stream := h.mcpStream(access, h.mcpSession(access))
	require.Equal(t, http.StatusOK, o.get("/account").status)

	bystander := h.owner("other@example.com")
	otherAgent := bystander.mac()
	h.dial(otherAgent)
	otherAccess, _ := bystander.approve(client, claudeCallback)

	out := h.command("account", "suspend", "Owner@Example.com", "abuse report 17")
	assert.Contains(t, out, "Suspended owner@example.com")

	// At once: these read the database on every request.
	assert.Equal(t, http.StatusUnauthorized, h.mcpStatus(access), "/mcp is refused")
	assert.Equal(t, http.StatusFound, o.get("/account").status, "the browser is signed out")
	tok := h.do(nil, http.MethodPost, "/token", "application/x-www-form-urlencoded",
		"grant_type=refresh_token&refresh_token="+refresh+"&client_id="+client, nil)
	assert.Equal(t, http.StatusBadRequest, tok.status, "no new token")
	status, body := h.postJSON("/auth/email", map[string]any{"email": "owner@example.com"})
	assert.Equal(t, http.StatusForbidden, status)
	assert.Equal(t, "This account has been suspended by the person who runs this relay. To ask about it, write to relay-owner@example.org.", body["error"])

	// Within the poll: what the relay held in memory.
	assert.Equal(t, agentproto.CloseAuthFailed, closeCode(t, mac), "the Mac is closed with 4001, not 4002: it keeps its key")
	assert.True(t, ended(stream, 5*time.Second), "Claude's open session is closed")
	_, err := agent.Dial(tctx(t))
	require.Error(t, err)
	assert.Equal(t, agentproto.CloseAuthFailed, testagent.CloseCode(err), "and refused while suspended")

	// Nothing is deleted, and nobody else is affected.
	d, err := h.db.Device(context.Background(), agent.DeviceID)
	require.NoError(t, err)
	assert.NotNil(t, d.PublicKey, "still paired")
	assert.Equal(t, http.StatusOK, h.mcpStatus(otherAccess))
	assert.True(t, h.relay.Hub.Online(otherAgent.DeviceID))
	assert.Equal(t, http.StatusOK, bystander.get("/account").status)

	out = h.command("account", "list")
	assert.Contains(t, out, "suspended")

	// Lifted: the same pairing connects, sign-in works, Claude has to be approved again.
	h.command("account", "unsuspend", "owner@example.com")
	again := h.dial(agent)
	assert.Empty(t, nextClients(t, again), "no app has access any more")
	assert.Equal(t, http.StatusUnauthorized, h.mcpStatus(access), "the old token stays dead")
	o.signIn()
	require.Equal(t, http.StatusOK, o.get("/account").status)
	fresh, _ := o.approve(client, claudeCallback)
	assert.Equal(t, http.StatusOK, h.mcpStatus(fresh))
}

// `account delete` has the effect of the Owner's own Delete account, also on a connected Mac:
// it is told it was disconnected (4002).
func TestDeletingAnAccountWhileTheRelayRuns(t *testing.T) {
	h := newHarness(t, nil)
	h.watch()
	o := h.owner("owner@example.com")
	mac := h.dial(o.mac())
	client := h.registerClient(claudeCallback)
	access, _ := o.approve(client, claudeCallback)

	assert.Contains(t, h.command("account", "delete", "owner@example.com"), "Deleted owner@example.com")
	assert.Equal(t, http.StatusUnauthorized, h.mcpStatus(access))
	assert.Equal(t, http.StatusFound, o.get("/account").status)
	assert.Equal(t, agentproto.CloseRevoked, closeCode(t, mac))
	_, err := h.db.User(context.Background(), o.user.ID)
	require.ErrorIs(t, err, store.ErrNotFound)
}

// `block` suspends the address's account, connections included, and refuses the address.
func TestBlockingAnAddressWhileTheRelayRuns(t *testing.T) {
	h := newHarness(t, nil)
	h.watch()
	o := h.owner("owner@example.com")
	mac := h.dial(o.mac())

	assert.Contains(t, h.command("block", "owner@example.com", "spam"), "Blocked owner@example.com")
	assert.Equal(t, agentproto.CloseAuthFailed, closeCode(t, mac))
	assert.Equal(t, http.StatusFound, o.get("/account").status)
	status, body := h.postJSON("/auth/email", map[string]any{"email": "owner@example.com"})
	assert.Equal(t, http.StatusForbidden, status)
	assert.Equal(t, "This email address can't be used on this relay.", body["error"])
	status, _ = h.postJSON("/auth/email", map[string]any{"email": "fresh@example.com"})
	assert.Equal(t, http.StatusOK, status, "other addresses can still sign up")
}

// The daily housekeeping drops old operator records and re-sends the list of apps to Macs.
func TestHousekeeping(t *testing.T) {
	h := newHarness(t, nil)
	ctx := context.Background()
	_, _, err := h.db.BlockEmail(ctx, "old@example.com", "", "test", time.Now().Add(-store.OperatorLogRetention-time.Hour))
	require.NoError(t, err)
	_, _, err = h.db.BlockEmail(ctx, "new@example.com", "", "test", time.Now())
	require.NoError(t, err)
	require.NoError(t, h.relay.Housekeeping(ctx))
	log, err := h.db.OperatorLogAfter(ctx, 0)
	require.NoError(t, err)
	require.Len(t, log, 1, "records older than a year are deleted (FR-199)")
	assert.Equal(t, "new@example.com", log[0].Email)
}

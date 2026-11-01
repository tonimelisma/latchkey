package hub_test

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/hub"
	"github.com/tonimelisma/latchkey/relay/internal/store"
	"github.com/tonimelisma/latchkey/relay/internal/testagent"
)

// grants is a pretend OAuth server: the list of apps with access per user.
type grants struct {
	mu      sync.Mutex
	list    []agentproto.Client
	revoked []string // "<user ID> <grant ID>"
}

func (g *grants) set(list ...agentproto.Client) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.list = list
}

func (g *grants) config(c *hub.Config) {
	c.Clients = func(_ context.Context, _ string) ([]agentproto.Client, error) {
		g.mu.Lock()
		defer g.mu.Unlock()
		return append([]agentproto.Client(nil), g.list...), nil
	}
	c.RevokeClient = func(_ context.Context, userID, id string) bool {
		g.mu.Lock()
		defer g.mu.Unlock()
		g.revoked = append(g.revoked, userID+" "+id)
		for i, cl := range g.list {
			if cl.ID == id {
				g.list = append(g.list[:i:i], g.list[i+1:]...)
				return true
			}
		}
		return false
	}
}

func client(id string) agentproto.Client {
	return agentproto.Client{
		ID: id, Name: "Claude", Host: "claude.ai", Redirect: "claude.ai",
		ApprovedAt: time.Date(2026, 10, 25, 16, 0, 0, 0, time.UTC),
	}
}

func nextClients(t *testing.T, c *testagent.Conn) *agentproto.Clients {
	t.Helper()
	select {
	case m := <-c.Clients:
		return m
	case <-time.After(3 * time.Second):
		t.Fatal("no clients message")
		return nil
	}
}

func noClients(t *testing.T, c *testagent.Conn) {
	t.Helper()
	select {
	case m := <-c.Clients:
		t.Fatalf("unexpected clients message: %+v", m)
	case <-time.After(300 * time.Millisecond):
	}
}

// An app that announced the feature gets the list right after welcome (FR-190).
func TestClientsSentAfterWelcomeWhenAnnounced(t *testing.T) {
	g := &grants{}
	g.set(client("grt_a"), client("grt_b"))
	e := setup(t, g.config)
	e.agent.Features = []string{agentproto.FeatureClients, "something_newer"}
	c := e.dial()
	m := nextClients(t, c)
	require.Len(t, m.Clients, 2)
	assert.Equal(t, "grt_a", m.Clients[0].ID)
	assert.Equal(t, "claude.ai", m.Clients[0].Host)
	assert.Nil(t, m.Clients[0].LastUsedAt)
}

// The installed app treats an unknown message type as a protocol violation, so an agent that
// didn't announce the feature never gets a clients message: not on connect, not on a change,
// not in answer to revoke_client.
func TestOldAgentsNeverReceiveClients(t *testing.T) {
	g := &grants{}
	g.set(client("grt_a"))
	e := setup(t, g.config)
	c := e.dial()
	e.waitOnline(true)
	noClients(t, c)
	g.set()
	e.hub.ClientsChanged(ctxT(t), e.user.ID)
	e.hub.RefreshClients(ctxT(t))
	noClients(t, c)
	require.NoError(t, c.Send(ctxT(t), &agentproto.RevokeClient{ID: "grt_a"}))
	noClients(t, c)
	assert.True(t, e.hub.Online(e.device.ID), "still connected")
}

// The list is sent again when it changes, and only then: a newer last-used time alone, or a
// change for another account, sends nothing.
func TestClientsSentAgainOnlyWhenTheListChanges(t *testing.T) {
	g := &grants{}
	g.set(client("grt_a"))
	e := setup(t, g.config)
	e.agent.Features = []string{agentproto.FeatureClients}
	c := e.dial()
	require.Len(t, nextClients(t, c).Clients, 1)
	e.waitOnline(true)

	e.hub.ClientsChanged(ctxT(t), e.user.ID)
	noClients(t, c)

	used := client("grt_a")
	at := time.Date(2026, 10, 25, 17, 0, 0, 0, time.UTC)
	used.LastUsedAt = &at
	g.set(used)
	e.hub.ClientsChanged(ctxT(t), e.user.ID)
	e.hub.RefreshClients(ctxT(t))
	noClients(t, c)

	g.set(used, client("grt_b"))
	e.hub.ClientsChanged(ctxT(t), "usr_someone_else")
	noClients(t, c)
	e.hub.ClientsChanged(ctxT(t), e.user.ID)
	m := nextClients(t, c)
	require.Len(t, m.Clients, 2)
	require.NotNil(t, m.Clients[0].LastUsedAt)
	assert.Equal(t, at, *m.Clients[0].LastUsedAt)

	g.set()
	e.hub.RefreshClients(ctxT(t)) // what the daily purge calls
	m = nextClients(t, c)
	assert.NotNil(t, m.Clients, "an empty list is [], never null")
	assert.Empty(t, m.Clients)
}

// revoke_client is handed to the OAuth side with this Mac's account, answered with the new list
// whether or not it removed anything, and recorded as metadata (FR-191).
func TestRevokeClientFromTheMac(t *testing.T) {
	g := &grants{}
	g.set(client("grt_a"), client("grt_b"))
	e := setup(t, g.config)
	e.agent.Features = []string{agentproto.FeatureClients}
	c := e.dial()
	require.Len(t, nextClients(t, c).Clients, 2)

	require.NoError(t, c.Send(ctxT(t), &agentproto.RevokeClient{ID: "grt_a"}))
	m := nextClients(t, c)
	require.Len(t, m.Clients, 1)
	assert.Equal(t, "grt_b", m.Clients[0].ID)

	require.NoError(t, c.Send(ctxT(t), &agentproto.RevokeClient{ID: "grt_of_someone_else"}))
	m = nextClients(t, c)
	require.Len(t, m.Clients, 1, "an unknown ID changes nothing and still gets the list")
	assert.True(t, e.hub.Online(e.device.ID), "and is not an error")

	g.mu.Lock()
	assert.Equal(t, []string{e.user.ID + " grt_a", e.user.ID + " grt_of_someone_else"}, g.revoked)
	g.mu.Unlock()

	var entries []store.AuditEntry
	require.Eventually(t, func() bool {
		var err error
		entries, err = e.store.AuditForUser(context.Background(), e.user.ID, 10)
		return err == nil && len(entries) == 2
	}, 3*time.Second, 10*time.Millisecond)
	assert.Equal(t, "revoke_client", entries[1].Tool)
	assert.Equal(t, store.OutcomeOK, entries[1].Outcome)
	assert.Equal(t, store.OutcomeError, entries[0].Outcome, "nothing was removed")
	assert.Equal(t, e.device.ID, entries[0].DeviceID)
	for _, en := range entries {
		assert.NotContains(t, en.Tool+en.Surface, "grt_", "the grant's ID is not recorded")
	}
}

// revoke_client is counted by the connection's frame allowance, like state (FR-091).
func TestRevokeClientCountsAgainstTheFrameAllowance(t *testing.T) {
	g := &grants{}
	e := setup(t, func(c *hub.Config) {
		g.config(c)
		c.FrameBurst, c.FrameInterval = 3, time.Hour
	})
	e.agent.NoHeartbeat = true
	e.agent.Features = []string{agentproto.FeatureClients}
	c := e.dial()
	e.waitOnline(true)
	for range 4 {
		_ = c.Send(ctxT(t), &agentproto.RevokeClient{ID: "grt_x"})
	}
	code, err := c.Wait(ctxT(t))
	require.NoError(t, err)
	assert.Equal(t, agentproto.CloseProtocolViolation, code)
}

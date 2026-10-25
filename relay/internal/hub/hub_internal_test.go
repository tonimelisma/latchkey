package hub

import (
	"context"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/store"
	"github.com/tonimelisma/latchkey/relay/internal/testagent"
)

// A Mac revoked after its signature was checked but before its connection was registered must
// not stay connected: Revoke found nothing to close at that moment, so the hub looks again once
// the connection is registered (FR-052a).
func TestRevokedDuringHandshakeIsClosed(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	st, err := store.Open(ctx, filepath.Join(t.TempDir(), "relay.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = st.Close() })
	h := New(st, Config{HeartbeatInterval: time.Second, PingInterval: time.Hour})
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)

	u, err := st.CreateUser(ctx, "owner@example.com", time.Now())
	require.NoError(t, err)
	agent := testagent.New("ws"+strings.TrimPrefix(srv.URL, "http"), "")
	d, err := st.CreateDevice(ctx, store.NewDevice{UserID: u.ID, Name: "Mac", PublicKey: agent.PublicKeyDER()}, time.Now())
	require.NoError(t, err)
	agent.DeviceID = d.ID

	// The Owner disconnects the Mac on the account page in the middle of its handshake.
	h.beforeRegister = func() {
		err := st.RevokeDevice(ctx, d.ID, time.Now())
		h.Revoke(d.ID)
		assert.NoError(t, err)
	}
	c, err := agent.Dial(ctx)
	if err != nil {
		assert.Equal(t, agentproto.CloseRevoked, testagent.CloseCode(err))
	} else {
		code, err := c.Wait(ctx)
		require.NoError(t, err)
		assert.Equal(t, agentproto.CloseRevoked, code)
	}
	require.Eventually(t, func() bool { return !h.Online(d.ID) }, 5*time.Second, 10*time.Millisecond,
		"a revoked Mac is not left registered")
}

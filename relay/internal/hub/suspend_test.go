package hub_test

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
)

// A suspended account's Mac is disconnected with 4001 and refused with 4001 while the
// suspension lasts: never 4002, on which the app would delete its key. Its pairing stays on the
// relay, so the same key connects again afterwards (FR-196).
func TestSuspendedAccountsMacIsRefusedWithoutUnpairing(t *testing.T) {
	e := setup(t, nil)
	c := e.dial()
	e.waitOnline(true)
	ctx := context.Background()

	// The operator's command changes the database; the relay then closes the open connection.
	_, changed, err := e.store.SuspendUser(ctx, "owner@example.com", "abuse", "root", time.Now())
	require.NoError(t, err)
	require.True(t, changed)
	e.hub.Suspend(e.device.ID)
	code, err := c.Wait(ctxT(t))
	require.NoError(t, err)
	assert.Equal(t, agentproto.CloseAuthFailed, code, "4001: the app shows Sign in again and keeps its key")
	e.waitOnline(false)

	assert.Equal(t, agentproto.CloseAuthFailed, e.dialRejected(e.agent), "refused while suspended")
	assert.False(t, e.hub.Online(e.device.ID))
	d, err := e.store.Device(ctx, e.device.ID)
	require.NoError(t, err)
	assert.NotNil(t, d.PublicKey, "the pairing is untouched")
	assert.True(t, d.RevokedAt.IsZero())

	_, _, err = e.store.UnsuspendUser(ctx, "owner@example.com", "root", time.Now())
	require.NoError(t, err)
	e.dial()
	e.waitOnline(true)
	e.hub.Suspend("dev_unknown") // harmless
}

// A Mac that connects in the moment its account is suspended (after its signature was checked,
// before the connection is registered, when nothing can close it yet) is closed right after.
func TestSuspensionDuringTheHandshakeIsCaught(t *testing.T) {
	e := setup(t, nil)
	e.hub.SetBeforeRegister(func() {
		_, _, err := e.store.SuspendUser(context.Background(), "owner@example.com", "", "root", time.Now())
		assert.NoError(t, err)
	})
	c, err := e.agent.Dial(ctxT(t))
	require.NoError(t, err, "welcome was already sent")
	code, err := c.Wait(ctxT(t))
	require.NoError(t, err)
	assert.Equal(t, agentproto.CloseAuthFailed, code)
	e.waitOnline(false)
}

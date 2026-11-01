package hub

import (
	"context"
	"slices"

	"github.com/tonimelisma/latchkey/relay/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Audit entry of a revoke_client from the Mac app: metadata only, never the grant's ID.
const (
	auditRevokeClient = "revoke_client"
	auditSurfaceApp   = "Latchkey app"
)

// ClientsChanged sends each of the user's connected machines that announced the feature (Macs)
// the list of apps with access, if it differs from the last one sent (FR-192).
func (h *Hub) ClientsChanged(ctx context.Context, userID string) {
	if h.cfg.Clients == nil {
		return
	}
	devices, err := h.store.ActiveDevices(ctx, userID)
	if err != nil {
		return // the account is gone
	}
	for _, d := range devices {
		if c := h.conn(d.ID); c != nil {
			c.sendClients(ctx, false)
		}
	}
}

// RefreshClients does the same for every connected Mac. The daily purge calls it, so a grant
// that expired leaves the list.
func (h *Hub) RefreshClients(ctx context.Context) {
	if h.cfg.Clients == nil {
		return
	}
	h.mu.Lock()
	conns := make([]*conn, 0, len(h.conns))
	for _, c := range h.conns {
		conns = append(conns, c)
	}
	h.mu.Unlock()
	for _, c := range conns {
		c.sendClients(ctx, false)
	}
}

// sendClients reads the list and writes it, under one lock, so two changes can't reach the Mac
// in the wrong order. Nothing is ever sent to an agent that didn't announce the feature: the app
// up to 0.8.9 takes an unknown message type for a protocol violation. Unless force is set (the
// first list after welcome, and the answer to revoke_client), a list equal to the last one sent,
// last-used times aside, is skipped.
func (c *conn) sendClients(ctx context.Context, force bool) {
	if !c.clientsFeature || c.hub.cfg.Clients == nil {
		return
	}
	ctx = context.WithoutCancel(ctx) // as for every frame to the Mac (FR-093)
	c.clientsMu.Lock()
	defer c.clientsMu.Unlock()
	list, err := c.hub.cfg.Clients(ctx, c.device.UserID)
	if err != nil {
		c.hub.cfg.Logger.Error("list apps with access", "device", c.device.ID, "err", err)
		return
	}
	if list == nil {
		list = []agentproto.Client{} // "clients": [], never null
	}
	if len(list) > agentproto.MaxClients {
		list = list[:agentproto.MaxClients]
	}
	if err := agentproto.ValidateClients(list); err != nil {
		c.hub.cfg.Logger.Error("list of apps with access not sent", "device", c.device.ID, "err", err)
		return
	}
	if !force && c.clientsSent && slices.EqualFunc(list, c.lastClients, sameClient) {
		return
	}
	if err := c.send(ctx, &agentproto.Clients{Clients: list}); err != nil {
		c.hub.cfg.Logger.Warn("send apps with access", "device", c.device.ID, "err", err)
		return
	}
	c.clientsSent, c.lastClients = true, list
	c.clientsSends++
}

// sameClient compares two entries without their last-used time, which alone is no reason to
// send the list again.
func sameClient(a, b agentproto.Client) bool {
	return a.ID == b.ID && a.Name == b.Name && a.Host == b.Host && a.Redirect == b.Redirect && a.ApprovedAt.Equal(b.ApprovedAt)
}

// revokeClient removes one app's access for this Mac's account, records it, and answers with
// the list as it is now, whether or not anything was removed (FR-191).
func (c *conn) revokeClient(ctx context.Context, m *agentproto.RevokeClient) {
	start := c.hub.now()
	removed := false
	c.clientsMu.Lock()
	sends := c.clientsSends
	c.clientsMu.Unlock()
	if c.hub.cfg.RevokeClient != nil {
		removed = c.hub.cfg.RevokeClient(context.WithoutCancel(ctx), c.device.UserID, m.ID)
	}
	// A removal has usually sent the new list already (ClientsChanged); the answer is sent here
	// only when nothing went out meanwhile, so the Mac gets one list per request.
	c.clientsMu.Lock()
	answered := c.clientsSends != sends
	c.clientsMu.Unlock()
	if !answered {
		c.sendClients(ctx, true)
	}
	outcome := store.OutcomeOK
	if !removed {
		outcome = store.OutcomeError
	}
	err := c.hub.store.AddAudit(context.WithoutCancel(ctx), store.AuditEntry{
		UserID: c.device.UserID, DeviceID: c.device.ID, At: start, Tool: auditRevokeClient,
		Surface: auditSurfaceApp, Outcome: outcome, Duration: c.hub.now().Sub(start),
	})
	if err != nil {
		c.hub.cfg.Logger.Error("audit", "err", err)
	}
}

// suspendedReason is the close reason of a 4001 that means "suspended", not a bad signature.
const suspendedReason = "account suspended"

// Suspend closes the device's connection because the relay's operator suspended its account
// (FR-196). The code is 4001, never 4002: the app deletes its key on 4002, and a suspension must
// not unpair the Mac. New connections are refused in the handshake while the suspension lasts.
func (h *Hub) Suspend(deviceID string) {
	if c := h.conn(deviceID); c != nil {
		c.closeWith(ErrDisconnected, agentproto.CloseAuthFailed, suspendedReason)
	}
}

// suspended reports whether the device's account is suspended right now.
func (h *Hub) suspended(ctx context.Context, userID string) bool {
	u, err := h.store.User(ctx, userID)
	return err == nil && !u.SuspendedAt.IsZero()
}

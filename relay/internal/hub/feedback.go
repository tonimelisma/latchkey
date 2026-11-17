package hub

import (
	"context"

	"github.com/tonimelisma/latchkey/relay/agentproto"
)

// Claude's feedback reports (spec 001 FR-692): sent to every connected Mac of the account that
// announced the feature, until one says it saved them.

// FeedbackFiled sends the account's waiting reports to its connected Macs that understand them.
func (h *Hub) FeedbackFiled(ctx context.Context, userID string) {
	devices, err := h.store.ActiveDevices(ctx, userID)
	if err != nil {
		return // the account is gone
	}
	for _, d := range devices {
		if c := h.conn(d.ID); c != nil {
			c.sendFeedback(ctx)
		}
	}
}

// sendFeedback sends the reports no Mac has saved yet, at most MaxFeedbackReports. Nothing is
// sent to an agent that didn't announce the feature: older apps take an unknown message type
// for a protocol violation. A report sent twice (filed while an earlier send waits for its
// answer) is saved once: the Mac doesn't write a report it already has.
func (c *conn) sendFeedback(ctx context.Context) {
	if !c.feedbackFeature {
		return
	}
	ctx = context.WithoutCancel(ctx) // as for every frame to the Mac (FR-093)
	c.feedbackMu.Lock()
	defer c.feedbackMu.Unlock()
	waiting, err := c.hub.store.WaitingFeedback(ctx, c.device.UserID, agentproto.MaxFeedbackReports)
	if err != nil {
		c.hub.cfg.Logger.Error("read feedback", "device", c.device.ID, "err", err)
		return
	}
	if len(waiting) == 0 {
		return
	}
	reports := make([]agentproto.FeedbackReport, 0, len(waiting))
	for _, f := range waiting {
		r := agentproto.FeedbackReport{
			ID: f.ID, At: f.At, Client: f.Client, Machine: f.Machine, Summary: f.Summary, Details: f.Details,
		}
		if agentproto.ValidateFeedbackReport(r) != nil {
			continue // stored by an older relay with other limits: never send what the Mac must refuse
		}
		reports = append(reports, r)
	}
	if len(reports) == 0 {
		return
	}
	if err := c.send(ctx, &agentproto.Feedback{Reports: reports}); err != nil {
		c.hub.cfg.Logger.Warn("send feedback", "device", c.device.ID, "err", err)
	}
}

// feedbackSaved marks the reports the Mac saved, then sends any still waiting (more than one
// message holds).
func (c *conn) feedbackSaved(ctx context.Context, m *agentproto.FeedbackSaved) {
	ctx = context.WithoutCancel(ctx)
	if err := c.hub.store.FeedbackDelivered(ctx, c.device.UserID, m.IDs, c.hub.now()); err != nil {
		c.hub.cfg.Logger.Error("mark feedback saved", "device", c.device.ID, "err", err)
		return
	}
	if len(m.IDs) == agentproto.MaxFeedbackReports {
		c.sendFeedback(ctx)
	}
}

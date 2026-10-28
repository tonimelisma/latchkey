package hub

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"

	"github.com/coder/websocket"

	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/events"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// noteEnd keeps the first close code and reason of the connection, from either side; code -1
// means no close frame (reason says what happened). Callers hold c.mu.
func (c *conn) noteEnd(code websocket.StatusCode, reason string) {
	if !c.ended {
		c.ended, c.endCode, c.endReason = true, code, reason
	}
}

// endedBy notes how a failed read ended the connection: the Mac's close frame, silence, a frame
// too big, or a lost connection.
func (c *conn) endedBy(err error, timedOut bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	var ce websocket.CloseError
	switch {
	case errors.As(err, &ce):
		c.noteEnd(ce.Code, ce.Reason)
	case timedOut:
		c.noteEnd(-1, fmt.Sprintf("no message for %s", c.hub.cfg.OfflineAfter))
	case strings.Contains(err.Error(), "read limited"):
		c.noteEnd(websocket.StatusMessageTooBig, "message too big")
	default:
		c.noteEnd(-1, "connection lost")
	}
}

// endDetail is the disconnection's detail: close code and reason, and the goodbye reason.
func (c *conn) endDetail() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	var parts []string
	switch {
	case !c.ended:
		parts = append(parts, "connection ended")
	case c.endCode == -1:
		parts = append(parts, c.endReason)
	case c.endReason == "":
		parts = append(parts, "close "+strconv.Itoa(int(c.endCode)))
	default:
		parts = append(parts, "close "+strconv.Itoa(int(c.endCode))+": "+truncate(c.endReason))
	}
	if c.goodbye != "" {
		parts = append(parts, "goodbye "+short(c.goodbye))
	}
	return strings.Join(parts, "; ")
}

// connectedEvent records the connection (FR-631) and, when the keep-awake state differs from the
// last one stored for this Mac, the change.
func (c *conn) connectedEvent(ctx context.Context, hello *agentproto.Hello, previousState []byte) {
	features := slices.Clone(hello.Features)
	slices.Sort(features)
	detail := fmt.Sprintf("app %s, macOS %s, keep-awake %s",
		short(hello.AppVersion), short(hello.OSVersion), short(hello.State.KeepAwake))
	if len(features) > 0 {
		detail += ", features " + short(strings.Join(features, " "))
	}
	c.hub.cfg.Events.Record(ctx, store.Event{
		Kind: events.MacConnected, UserID: c.device.UserID, DeviceID: c.device.ID, Detail: detail,
	})
	var before agentproto.State
	if previousState != nil && json.Unmarshal(previousState, &before) == nil && before.KeepAwake != hello.State.KeepAwake {
		c.recordKeepAwake(ctx, hello.State.KeepAwake, before.KeepAwake)
	}
}

// keepAwakeChanged records a keep-awake state that differs from the last one reported.
func (c *conn) keepAwakeChanged(ctx context.Context, now string) {
	c.mu.Lock()
	before := c.keepAwake
	c.keepAwake = now
	c.mu.Unlock()
	if before != now {
		c.recordKeepAwake(ctx, now, before)
	}
}

func (c *conn) recordKeepAwake(ctx context.Context, now, before string) {
	c.hub.cfg.Events.Record(ctx, store.Event{
		Kind: events.KeepAwake, UserID: c.device.UserID, DeviceID: c.device.ID,
		Detail: short(now) + " (was " + short(before) + ")",
	})
}

// short keeps a value the Mac reports to a sensible length for the record.
func short(s string) string {
	switch {
	case s == "":
		return "unknown"
	case len(s) > 64:
		return s[:64]
	}
	return s
}

// answerAudit sends one page of this Mac's audit (FR-634). An invalid since or limit gets an
// empty page; so does a failed read, which is logged, so the app reports the comparison as not
// possible rather than waiting.
func (c *conn) answerAudit(ctx context.Context, m *agentproto.AuditRequest) {
	answer := &agentproto.Audit{ID: m.ID}
	if m.Valid() {
		rows, next, err := c.hub.store.AuditForDevice(ctx, c.device.ID, m.Since, m.PageSize())
		if err != nil {
			c.hub.cfg.Logger.Error("read audit for the Mac", "device", c.device.ID, "err", err)
		} else {
			answer.NextSince = next
			answer.Entries = make([]agentproto.AuditEntry, 0, len(rows))
			for _, r := range rows {
				answer.Entries = append(answer.Entries, agentproto.AuditEntry{
					CallID: r.CallID, At: r.At.UnixMilli(), Tool: r.Tool, Outcome: r.Outcome,
					DurationMS: r.Duration.Milliseconds(),
				})
			}
		}
	}
	if err := c.send(ctx, answer); err != nil {
		c.hub.cfg.Logger.Warn("send audit", "device", c.device.ID, "err", err)
	}
}

package server

import (
	"context"
	"log/slog"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/hub"
	"github.com/tonimelisma/latchkey/relay/internal/mcpserver"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// OperatorPoll is how often the running relay looks for operator commands run beside it
// (FR-198 asks for open connections to follow within 5 seconds).
const OperatorPoll = 2 * time.Second

// operatorWatch makes the running relay follow commands the operator runs in another process
// against the same database (plan D14). Everything the relay checks per request reads the
// database and needs no notice: sessions, tokens, sign-in, the Mac's handshake. What is held in
// memory does: the Mac's open connection and Claude's open sessions. The watch reads the
// operator log for entries newer than the last one it handled and closes those.
type operatorWatch struct {
	store  *store.Store
	hub    *hub.Hub
	mcp    *mcpserver.Server
	logger *slog.Logger
	last   int64 // ID of the newest entry handled
}

// newOperatorWatch starts from the log as it is now: commands from before this start have
// nothing in memory to close.
func newOperatorWatch(ctx context.Context, st *store.Store, h *hub.Hub, ms *mcpserver.Server, logger *slog.Logger) (*operatorWatch, error) {
	last, err := st.LastOperatorLogID(ctx)
	if err != nil {
		return nil, err
	}
	if logger == nil {
		logger = slog.Default()
	}
	return &operatorWatch{store: st, hub: h, mcp: ms, logger: logger, last: last}, nil
}

func (w *operatorWatch) run(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			w.poll(ctx)
		}
	}
}

func (w *operatorWatch) poll(ctx context.Context) {
	entries, err := w.store.OperatorLogAfter(ctx, w.last)
	if err != nil {
		if ctx.Err() == nil {
			w.logger.Error("read operator log", "err", err)
		}
		return
	}
	for _, e := range entries {
		w.last = e.ID
		w.apply(e)
	}
}

func (w *operatorWatch) apply(e store.OperatorEntry) {
	if e.UserID == "" {
		return // an address without an account
	}
	switch e.Action {
	case store.OpSuspend, store.OpBlock:
		// 4001, so the app keeps its pairing; the handshake refuses it while suspended (FR-196).
		if e.DeviceID != "" {
			w.hub.Suspend(e.DeviceID)
		}
		w.mcp.Forget(e.UserID)
	case store.OpDelete:
		// As the Owner's own Delete account: the Mac is told it was disconnected (4002).
		if e.DeviceID != "" {
			w.hub.Revoke(e.DeviceID)
		}
		w.mcp.Forget(e.UserID)
	default:
		return
	}
	w.logger.Info("operator command applied", "action", e.Action, "user", e.UserID)
}

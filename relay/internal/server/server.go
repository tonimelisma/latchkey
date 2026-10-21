// Package server assembles the relay from its parts. The relay command, the end-to-end test,
// and the local Claude Code check all build it here, the same way.
package server

import (
	"context"
	"log/slog"
	"net/http"
	"net/url"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/account"
	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/hub"
	"github.com/tonimelisma/latchkey/relay/internal/mcpserver"
	"github.com/tonimelisma/latchkey/relay/internal/oauth"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Relay is the assembled server.
type Relay struct {
	Handler http.Handler
	Hub     *hub.Hub
	Store   *store.Store
}

// Options configures the relay.
type Options struct {
	PublicURL     *url.URL
	Store         *store.Store
	Mailer        account.Mailer
	AllowedEmails []string
	Logger        *slog.Logger
	Version       string
	Hub           hub.Config // timing overrides for tests
}

// New builds the relay: hub, MCP server, OAuth, and account pages on one mux.
func New(ctx context.Context, o Options) (*Relay, error) {
	var (
		ms  *mcpserver.Server
		acc *account.Service
	)
	hc := o.Hub
	hc.Logger = o.Logger
	hc.OnToolsChanged = func(userID string) { ms.ToolsChanged(userID) }
	hc.NoticesOnConnect = func(ctx context.Context, d store.Device, previous time.Time) []*agentproto.Notice {
		return acc.NoticesOnConnect(ctx, d, previous)
	}
	h := hub.New(o.Store, hc)
	ms = mcpserver.New(o.Store, h, mcpserver.Options{Logger: o.Logger, Version: o.Version})

	auth := &authBridge{}
	oa, err := oauth.New(ctx, oauth.Config{Issuer: o.PublicURL, Store: o.Store, Auth: auth})
	if err != nil {
		return nil, err
	}
	acc, err = account.New(ctx, account.Config{
		PublicURL: o.PublicURL, Store: o.Store, Macs: h, Mailer: o.Mailer, OAuth: oa,
		AllowedEmails: o.AllowedEmails, Logger: o.Logger,
		DevicesChanged: func(userID string) { ms.ToolsChanged(userID) },
	})
	if err != nil {
		return nil, err
	}
	auth.Service = acc

	mux := http.NewServeMux()
	mux.Handle("GET /agent/v1", h)
	mux.Handle("/mcp", oa.Protect(ms))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok\n")) })
	oa.Register(mux)
	acc.Register(mux)
	return &Relay{Handler: mux, Hub: h, Store: o.Store}, nil
}

// authBridge lets the OAuth server use the account service, which needs the OAuth server.
type authBridge struct{ *account.Service }

// AuditRetention is how long audit entries are kept (FR-024).
const AuditRetention = 30 * 24 * time.Hour

// Purge runs the retention jobs at startup and then daily (FR-024, Constitution VI).
func Purge(ctx context.Context, db *store.Store, logger *slog.Logger) {
	t := time.NewTicker(24 * time.Hour)
	defer t.Stop()
	for {
		now := time.Now()
		if n, err := db.PurgeAudit(ctx, now.Add(-AuditRetention)); err != nil {
			logger.Error("purge audit log", "err", err)
		} else if n > 0 {
			logger.Info("purged audit log", "rows", n)
		}
		if err := db.PurgeExpired(ctx, now); err != nil {
			logger.Error("purge expired sign-in data", "err", err)
		}
		if _, err := db.PurgeUnverifiedUsers(ctx, now.Add(-24*time.Hour)); err != nil {
			logger.Error("purge unverified sign-ups", "err", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

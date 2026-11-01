// Package server assembles the relay from its parts. The relay command, the end-to-end test,
// and the local Claude Code check all build it here, the same way.
package server

import (
	"context"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/tonimelisma/latchkey/relay/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/account"
	"github.com/tonimelisma/latchkey/relay/internal/events"
	"github.com/tonimelisma/latchkey/relay/internal/hub"
	"github.com/tonimelisma/latchkey/relay/internal/limit"
	"github.com/tonimelisma/latchkey/relay/internal/mcpserver"
	"github.com/tonimelisma/latchkey/relay/internal/oauth"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Relay is the assembled server.
type Relay struct {
	Handler http.Handler
	Hub     *hub.Hub
	Store   *store.Store
	// Housekeeping runs after the daily purge: the operator log's retention (FR-199), and the
	// list of apps with access re-sent to every connected Mac, since the purge is where an
	// expired approval is found (FR-192). Pass it to Purge.
	Housekeeping func(context.Context) error
	// WatchOperator makes the running relay follow the operator's commands (see operator.go).
	// Run it in its own goroutine; it returns when ctx ends.
	WatchOperator func(ctx context.Context, every time.Duration)
	// PurgeClients deletes stored OAuth clients the operator's list no longer allows (FR-184);
	// pass it to Purge.
	PurgeClients func(context.Context) error
	// Events is the relay's event record (FR-631).
	Events *events.Recorder
	// grantExpired records an approval the purge removed and tells the rest of the relay.
	grantExpired func(context.Context, store.Grant)
}

// Options configures the relay.
type Options struct {
	PublicURL     *url.URL
	Store         *store.Store
	Mailer        account.Mailer
	SetupCode     string // spec 009 FR-907
	AllowedEmails []string
	Logger        *slog.Logger
	Version       string
	Hub           hub.Config // timing overrides for tests
	// TrustedProxies whose X-Forwarded-For is believed, besides loopback (FR-082).
	TrustedProxies limit.TrustedProxies
	// Operator is who runs this relay (OPERATOR_NAME and the rest): with a name and a contact
	// the relay publishes its terms and privacy policy (FR-193).
	Operator account.Operator
	// AllowedClients is the hosts whose clients may ask for access (FR-180). The zero value is
	// the default: Claude's apps only.
	AllowedClients oauth.AllowedHosts
}

// New builds the relay: hub, MCP server, OAuth, and account pages on one mux.
func New(ctx context.Context, o Options) (*Relay, error) {
	var (
		ms  *mcpserver.Server
		acc *account.Service
	)
	rec := events.New(o.Store, o.Logger, nil)
	hc := o.Hub
	hc.Logger = o.Logger
	hc.Events = rec
	hc.OnToolsChanged = func(userID string) { ms.ToolsChanged(userID) }
	hc.NoticesOnConnect = func(ctx context.Context, d store.Device, previous time.Time) []*agentproto.Notice {
		return acc.NoticesOnConnect(ctx, d, previous)
	}
	var oa *oauth.Server
	hc.Clients = func(ctx context.Context, userID string) ([]agentproto.Client, error) {
		return clientsFor(ctx, oa, userID)
	}
	hc.RevokeClient = func(ctx context.Context, userID, id string) bool {
		removed, err := oa.RevokeGrant(ctx, userID, id, "from the Mac app")
		if err != nil {
			o.Logger.Error("remove app's access", "err", err)
		}
		return removed
	}
	h := hub.New(o.Store, hc)
	ms = mcpserver.New(o.Store, h, mcpserver.Options{Logger: o.Logger, Version: o.Version})

	auth := &authBridge{}
	oc := oauth.Config{
		Issuer: o.PublicURL, Store: o.Store, Auth: auth, Logger: o.Logger, AllowedClients: o.AllowedClients, Events: rec,
		OnAuthorized: func(ctx context.Context, userID, clientName string) { acc.ClientAuthorized(ctx, userID, clientName) },
		// The Mac's list of apps with access follows every change (FR-192), and an app whose
		// access ended loses its open sessions while the others keep theirs (FR-191).
		OnGrantsChanged: func(ctx context.Context, userID string) { h.ClientsChanged(ctx, userID) },
		OnGrantRemoved:  func(userID, grantID string) { ms.ForgetGrant(userID, grantID) },
	}
	if o.Operator.Published() {
		origin := strings.TrimSuffix(o.PublicURL.String(), "/")
		oc.TermsURI, oc.PolicyURI = origin+"/terms", origin+"/privacy"
	}
	var err error
	oa, err = oauth.New(ctx, oc)
	if err != nil {
		return nil, err
	}
	acc, err = account.New(ctx, account.Config{
		PublicURL: o.PublicURL, Store: o.Store, Macs: h, Mailer: o.Mailer, SetupCode: o.SetupCode, OAuth: oa,
		AllowedEmails: o.AllowedEmails, Logger: o.Logger, Operator: o.Operator, Events: rec,
		DevicesChanged: func(userID string) { ms.ToolsChanged(userID) },
		AccessRemoved:  func(userID string) { ms.Forget(userID) },
	})
	if err != nil {
		return nil, err
	}
	auth.Service = acc

	mux := http.NewServeMux()
	mux.Handle("GET /agent/v1", h)
	mux.Handle("/mcp", oa.Protect(perUser(ms)))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok\n")) })
	oa.Register(mux)
	acc.Register(mux)
	r := &Relay{
		Handler: guard(o.PublicURL, o.TrustedProxies, rec, mux), Hub: h, Store: o.Store, Events: rec,
		grantExpired: oa.GrantExpired,
	}
	r.PurgeClients = func(ctx context.Context) error {
		_, err := oa.PurgeRefusedClients(ctx)
		return err
	}
	r.Housekeeping = func(ctx context.Context) error {
		h.RefreshClients(ctx)
		return o.Store.PurgeOperatorLog(ctx, time.Now().Add(-store.OperatorLogRetention))
	}
	w, err := newOperatorWatch(ctx, o.Store, h, ms, o.Logger)
	if err != nil {
		return nil, err
	}
	r.WatchOperator = w.run
	return r, nil
}

// clientsFor is the Owner's apps with access as the agent protocol lists them: times in whole
// seconds, last use null until there was one.
func clientsFor(ctx context.Context, oa *oauth.Server, userID string) ([]agentproto.Client, error) {
	grants, err := oa.Grants(ctx, userID)
	if err != nil {
		return nil, err
	}
	out := make([]agentproto.Client, 0, len(grants))
	for _, g := range grants {
		c := agentproto.Client{
			ID: g.ID, Name: g.Name, Host: g.Host, Redirect: g.Redirect, ApprovedAt: g.ApprovedAt.UTC().Truncate(time.Second),
		}
		if !g.LastUsedAt.IsZero() {
			at := g.LastUsedAt.UTC().Truncate(time.Second)
			c.LastUsedAt = &at
		}
		out = append(out, c)
	}
	return out, nil
}

// authBridge lets the OAuth server use the account service, which needs the OAuth server.
type authBridge struct{ *account.Service }

// ClientAuthorizationRetention is how long the record of an app given access is kept for telling
// the Owner's Mac (data-model.md, client_authorizations). The audit and the event record are
// not purged at all (FR-024, FR-630).
const ClientAuthorizationRetention = 30 * 24 * time.Hour

// Purge runs the relay's daily housekeeping (Daily) at startup and then once a day.
func Purge(ctx context.Context, r *Relay, logger *slog.Logger) {
	t := time.NewTicker(24 * time.Hour)
	defer t.Stop()
	for {
		r.Daily(ctx, time.Now(), logger)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// Daily deletes what has expired as of now (Constitution VI): sessions, codes, tokens, approvals
// with no token left, unfinished sign-ups, clients the operator's list refuses, and the operator
// log's old entries. It deletes nothing from the audit or the event record, whatever their age
// (FR-024, FR-630).
func (r *Relay) Daily(ctx context.Context, now time.Time, logger *slog.Logger) {
	db := r.Store
	if err := db.PurgeClientAuthorizations(ctx, now.Add(-ClientAuthorizationRetention)); err != nil {
		logger.Error("purge client authorizations", "err", err)
	}
	if err := db.PurgeDevicePairings(ctx, now); err != nil {
		logger.Error("purge device pairings", "err", err)
	}
	ended, err := db.PurgeExpired(ctx, now)
	if err != nil {
		logger.Error("purge expired sign-in data", "err", err)
	}
	for _, g := range ended {
		r.grantExpired(ctx, g)
	}
	if _, err := db.PurgeUnverifiedUsers(ctx, now.Add(-24*time.Hour)); err != nil {
		logger.Error("purge unverified sign-ups", "err", err)
	}
	for _, job := range []func(context.Context) error{r.PurgeClients, r.Housekeeping} {
		if err := job(ctx); err != nil {
			logger.Error("purge", "err", err)
		}
	}
}

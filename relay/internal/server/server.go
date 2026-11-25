// Package server assembles the relay from its parts. The relay command, the end-to-end test,
// and the local Claude Code check all build it here, the same way.
package server

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/reportlog"

	"github.com/tonimelisma/latchkey/relay/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/account"
	"github.com/tonimelisma/latchkey/relay/internal/events"
	"github.com/tonimelisma/latchkey/relay/internal/hub"
	"github.com/tonimelisma/latchkey/relay/internal/limit"
	"github.com/tonimelisma/latchkey/relay/internal/mcpserver"
	"github.com/tonimelisma/latchkey/relay/internal/oauth"
	"github.com/tonimelisma/latchkey/relay/internal/store"
	"github.com/tonimelisma/latchkey/relay/internal/trace"
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
	// Traces is the accounts' trace files (FR-683), or nil.
	Traces *trace.Store
	// DrainMail waits, until ctx ends, for the emails being sent in the background (recovery
	// codes, security emails): call it at shutdown, after the last request is answered.
	DrainMail func(context.Context)
	// grantExpired records an approval the purge removed and tells the rest of the relay.
	grantExpired func(context.Context, store.Grant)
	// SendReports delivers the problem reports users chose to share to the developer's intake
	// until ctx ends (spec 014 FR-1414). Run it in its own goroutine.
	SendReports func(ctx context.Context)
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
	// Traces keeps each account's full trace (FR-683): every relay has one (TraceOptions); nil
	// keeps none, for tests that don't look at traces.
	Traces *trace.Store
	// Reports is where the problem reports users chose to share go (spec 014); the zero value
	// offers no feedback tool.
	Reports mcpserver.ReportsOptions
}

// TraceDirName is the trace folder's name in the relay's data folder.
const TraceDirName = "traces"

// TraceOptions is how a relay with its database in dataDir keeps its traces: in
// dataDir/traces, sealed with a key derived from the key file (FR-683), and only for accounts
// that exist. The server and the operator's commands open them the same way.
func TraceOptions(st *store.Store, dataDir string) (trace.Options, error) {
	key, err := st.DeriveKey(trace.KeyInfo)
	if err != nil {
		return trace.Options{}, err
	}
	return trace.Options{
		Dir: filepath.Join(dataDir, TraceDirName), Key: key,
		AccountExists: func(id string) bool {
			_, err := st.User(context.Background(), id)
			return !errors.Is(err, store.ErrNotFound) // a failing database read keeps the line
		},
	}, nil
}

// traceEvents sends the account's events to its trace, and reports the low-disk pause as
// operator events (FR-683, FR-684).
func traceEvents(st *store.Store, rec *events.Recorder, ts *trace.Store) {
	if ts == nil {
		return
	}
	rec.TraceTo(func(e store.Event) {
		if e.UserID == "" {
			return // an operator event: no account's trace
		}
		machine := ""
		if e.DeviceID != "" {
			if d, err := st.Device(context.Background(), e.DeviceID); err == nil {
				machine = d.Name
			}
		}
		ts.Append(e.UserID, e.At, trace.Event(e.Kind, e.Detail, machine))
	})
	ts.OnPauseChange(func(paused bool, free uint64) {
		gib := float64(free) / (1 << 30)
		e := store.Event{Kind: events.TracesResumed, Detail: fmt.Sprintf("%.1f GiB free; traces are written again", gib)}
		if paused {
			e = store.Event{Kind: events.TracesPaused, Detail: fmt.Sprintf("%.1f GiB free, less than 2 GiB; no traces are written until there is more, and none are deleted", gib)}
		}
		rec.Record(context.Background(), e)
	})
}

// New builds the relay: hub, MCP server, OAuth, and account pages on one mux.
func New(ctx context.Context, o Options) (*Relay, error) {
	var (
		ms  *mcpserver.Server
		acc *account.Service
	)
	if o.Logger == nil {
		o.Logger = slog.Default()
	}
	// The relay's lines about each account, kept in memory for its problem reports (spec 014
	// FR-1442); every line still goes to the relay's own log.
	relayLog := reportlog.New(nil)
	o.Logger = slog.New(relayLog.Wrap(o.Logger.Handler()))
	rec := events.New(o.Store, o.Logger, nil)
	traceEvents(o.Store, rec, o.Traces)
	hc := o.Hub
	hc.Logger = o.Logger
	hc.Events = rec
	hc.OnToolsChanged = func(userID string) { ms.ToolsChanged(userID) }
	hc.OnSharingChanged = func(userID string) { ms.SharingChanged(userID) }
	hc.ReportsBlocked = o.Reports.Blocked
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
	ms = mcpserver.New(o.Store, h, mcpserver.Options{Logger: o.Logger, Version: o.Version, Traces: o.Traces, Reports: o.Reports, RelayLog: relayLog, PublicURL: o.PublicURL})

	auth := &authBridge{}
	oc := oauth.Config{
		Issuer: o.PublicURL, Store: o.Store, Auth: auth, Logger: o.Logger, AllowedClients: o.AllowedClients, Events: rec,
		OnAuthorized: func(ctx context.Context, userID, clientName, redirectHost string) {
			acc.ClientAuthorized(ctx, userID, clientName, redirectHost)
		},
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
		AllowedEmails: o.AllowedEmails, Logger: o.Logger, Operator: o.Operator, Events: rec, Traces: o.Traces,
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
		Handler: guard(o.PublicURL, o.TrustedProxies, rec, mux), Hub: h, Store: o.Store, Events: rec, Traces: o.Traces,
		grantExpired: oa.GrantExpired, DrainMail: acc.DrainMail,
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
	r.SendReports = ms.SendReports
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
	gone, err := db.PurgeUnverifiedUsers(ctx, now.Add(-24*time.Hour))
	if err != nil {
		logger.Error("purge unverified sign-ups", "err", err)
	}
	for _, id := range gone { // their traces go with them (FR-687)
		if err := r.Traces.Delete(id); err != nil {
			logger.Error("remove the traces of an unfinished sign-up", "user", id, "err", err)
		}
	}
	for _, job := range []func(context.Context) error{r.PurgeClients, r.Housekeeping} {
		if err := job(ctx); err != nil {
			logger.Error("purge", "err", err)
		}
	}
}

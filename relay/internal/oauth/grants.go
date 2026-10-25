package oauth

import (
	"context"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/ory/fosite"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// GrantExtra is the key in auth.TokenInfo.Extra under which the bearer check names the grant a
// request belongs to, by its public ID. The MCP layer uses it to close one grant's sessions.
const GrantExtra = "latchkey_grant"

// MaxGrants is the most apps with access that are listed (the agent protocol's cap).
const MaxGrants = 50

const (
	unnamedApp   = "An unnamed app"
	thisComputer = "this computer" // where a loopback redirect goes
	// touchEvery is how often a grant's last use is written at most (FR-192).
	touchEvery = time.Minute
	// maxTouched bounds the in-memory record of recent writes.
	maxTouched = 10000
)

// Grant is one app with access: one approval the Owner gave on the consent page that still
// holds a live token (FR-190). All of Claude's hosted apps share a client ID, so two grants can
// name the same client; the grant is what is listed and removed.
type Grant struct {
	ID         string // public handle: not a token, not the client ID
	Name       string // the client's name as the consent page showed it
	Host       string // the host the relay checked
	Redirect   string // the host the approval was sent back to, or "this computer"
	ApprovedAt time.Time
	LastUsedAt time.Time // zero until first used
}

// Label is the grant's name with its checked host, e.g. "Claude (claude.ai)".
func (g Grant) Label() string {
	name := g.Name
	if name == unnamedApp {
		name = ""
	}
	return clientLabel(name, g.Host)
}

// redirectLabel is what the Owner is told about where an approval was sent: the redirect URI's
// host, or "this computer" for a loopback address.
func redirectLabel(u *url.URL) string {
	if u == nil || u.Hostname() == "" {
		return ""
	}
	if isLoopbackHost(u.Hostname()) {
		return thisComputer
	}
	return displayHost(u.Hostname())
}

// recordGrant stores the approval the Owner just gave, with what the consent page showed.
func (s *Server) recordGrant(ctx context.Context, ar fosite.AuthorizeRequester, userID string) error {
	c := consentFor(ar)
	return s.cfg.Store.AddGrant(ctx, store.Grant{
		RequestID: ar.GetID(), ID: store.NewGrantID(), UserID: userID, ClientID: ar.GetClient().GetID(),
		ClientName: c.ClientName, ClientHost: c.ClientHost, Redirect: redirectLabel(ar.GetRedirectURI()),
		ApprovedAt: s.cfg.Now().UTC(),
	})
}

// consentFor is what the consent page shows for an authorization request.
func consentFor(ar fosite.AuthorizeRequester) ConsentRequest {
	c := ConsentRequest{
		RedirectHost: displayHost(ar.GetRedirectURI().Host),
		ClientHost:   strings.Join(verifiedHosts(ar.GetClient(), ar.GetRedirectURI()), ", "),
	}
	if cl, ok := ar.GetClient().(*client); ok {
		c.ClientName = cleanName(cl.Name)
	}
	return c
}

// Grants lists the Owner's apps with access, newest approval first, at most MaxGrants.
func (s *Server) Grants(ctx context.Context, userID string) ([]Grant, error) {
	rows, err := s.cfg.Store.LiveGrants(ctx, userID, s.cfg.Now(), MaxGrants)
	if err != nil {
		return nil, err
	}
	out := make([]Grant, 0, len(rows))
	for _, r := range rows {
		g := Grant{
			ID: r.ID, Name: r.ClientName, Host: r.ClientHost, Redirect: r.Redirect,
			ApprovedAt: r.ApprovedAt, LastUsedAt: r.LastUsedAt,
		}
		if g.Host == "" || g.Redirect == "" {
			s.labelFromClient(ctx, r.ClientID, &g)
		}
		if g.Name == "" {
			g.Name = unnamedApp
		}
		out = append(out, g)
	}
	return out, nil
}

// labelFromClient names a grant from before labels were stored (migration 10) by what the relay
// knows of its client; the first registered redirect stands in for where the approval went.
func (s *Server) labelFromClient(ctx context.Context, clientID string, g *Grant) {
	const unknown = "unknown"
	cl, err := s.clients.get(ctx, clientID)
	if err != nil {
		g.Host, g.Redirect = unknown, unknown
		return
	}
	g.Name = cleanName(cl.Name)
	if g.Host = strings.Join(verifiedHosts(cl, nil), ", "); g.Host == "" {
		g.Host = unknown
	}
	g.Redirect = unknown
	for _, raw := range cl.GetRedirectURIs() {
		if u, err := url.Parse(raw); err == nil && redirectLabel(u) != "" {
			g.Redirect = redirectLabel(u)
			break
		}
	}
}

// RevokeGrant removes one app's access: the grant's codes and tokens are deleted, its open
// sessions are closed, and the Owner's Mac is sent the new list. A grant of another account,
// or an unknown ID, changes nothing and reports false (FR-191).
func (s *Server) RevokeGrant(ctx context.Context, userID, grantID string) (bool, error) {
	removed, err := s.cfg.Store.DeleteGrant(ctx, userID, grantID)
	if err != nil || !removed {
		return false, err
	}
	s.grantEnded(ctx, userID, grantID)
	return true, nil
}

// grantEnded tells the rest of the relay that a grant no longer has access.
func (s *Server) grantEnded(ctx context.Context, userID, grantID string) {
	if s.cfg.OnGrantRemoved != nil {
		s.cfg.OnGrantRemoved(userID, grantID)
	}
	s.grantsChanged(ctx, userID)
}

func (s *Server) grantsChanged(ctx context.Context, userID string) {
	if s.cfg.OnGrantsChanged != nil {
		s.cfg.OnGrantsChanged(ctx, userID)
	}
}

// revoked runs after fosite revoked tokens of a grant (a client's /revoke, a refresh token used
// again, a code replayed): if the grant has no access left, the relay is told.
func (s *Server) revoked(ctx context.Context, requestID string) {
	g, err := s.cfg.Store.GrantByRequest(ctx, requestID)
	if err != nil {
		return
	}
	if live, err := s.cfg.Store.GrantLive(ctx, requestID, s.cfg.Now()); err != nil || live {
		return
	}
	s.grantEnded(ctx, g.UserID, g.ID)
}

// touches remembers when each grant's last use was last written, so a request writes it at most
// once per touchEvery and most requests write nothing.
type touches struct {
	mu   sync.Mutex
	last map[string]touch // request ID → its grant and last write
}

type touch struct {
	grantID string
	at      time.Time
}

// recent returns the grant's public ID if its last use was written within touchEvery: nothing
// needs reading or writing then.
func (t *touches) recent(requestID string, now time.Time) (string, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	e, ok := t.last[requestID]
	return e.grantID, ok && now.Sub(e.at) < touchEvery
}

// note records that the grant's last use was written at now.
func (t *touches) note(requestID, grantID string, now time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if len(t.last) >= maxTouched {
		for id, e := range t.last {
			if now.Sub(e.at) >= touchEvery {
				delete(t.last, id)
			}
		}
		if len(t.last) >= maxTouched { // all recent: start over rather than grow
			t.last = map[string]touch{}
		}
	}
	t.last[requestID] = touch{grantID, now}
}

// used is called for every request that presents a live access token: it returns the public ID
// of the token's grant and records the use, writing at most once per touchEvery per grant.
func (s *Server) used(ctx context.Context, requestID string) string {
	now := s.cfg.Now()
	if id, ok := s.touched.recent(requestID, now); ok {
		return id
	}
	g, err := s.cfg.Store.GrantByRequest(ctx, requestID)
	if err != nil {
		return "" // a token with no grant row: nothing to name or record
	}
	if err := s.cfg.Store.TouchGrant(ctx, requestID, now); err != nil {
		s.cfg.Logger.Error("record grant use", "err", err)
	}
	s.touched.note(requestID, g.ID, now)
	return g.ID
}

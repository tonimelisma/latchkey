package oauth

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"net/url"
	"slices"
	"strings"

	"github.com/zitadel/oidc/v3/pkg/oidc"
	"golang.org/x/net/idna"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// defaultClientHost is where every Claude app publishes its client metadata document and where
// the hosted apps receive their codes (research.md, "Which clients may ask for access").
const defaultClientHost = "claude.ai"

// AllowedHosts is the operator's list of hosts whose clients may ask for access (FR-180 to
// FR-185). The zero value is the default list, Claude's apps only, so code that forgets to set
// it never accepts everyone.
type AllowedHosts struct {
	any   bool
	hosts []string // lowercase ASCII, exact names
}

// AnyClientHost accepts clients from every host, and dynamic registration (the setting "*").
func AnyClientHost() AllowedHosts { return AllowedHosts{any: true} }

// ParseAllowedHosts reads the ALLOWED_CLIENT_HOSTS setting: host names separated by commas, or
// the single value "*". Empty means the default.
func ParseAllowedHosts(s string) (AllowedHosts, error) {
	s = strings.TrimSpace(s)
	switch s {
	case "":
		return AllowedHosts{}, nil
	case "*":
		return AnyClientHost(), nil
	}
	var a AllowedHosts
	for entry := range strings.SplitSeq(s, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		if entry == "*" {
			return AllowedHosts{}, errors.New(`"*" (any host) can't be combined with host names`)
		}
		h, ok := normalHost(entry)
		if !ok {
			return AllowedHosts{}, fmt.Errorf("%q is not a host name (write names like claude.ai: no https://, port, path, or wildcard)", entry)
		}
		if !slices.Contains(a.hosts, h) {
			a.hosts = append(a.hosts, h)
		}
	}
	if len(a.hosts) == 0 {
		return AllowedHosts{}, errors.New("no host names given")
	}
	return a, nil
}

// normalHost is a host in the form the list compares: an IP address as Go prints it, or a
// domain name in lowercase IDNA ASCII form. Anything else (a port, a path, a wildcard, a
// trailing dot, an empty label) is not a host.
func normalHost(h string) (string, bool) {
	h = strings.ToLower(h)
	if ip, err := netip.ParseAddr(h); err == nil {
		return ip.WithZone("").String(), true
	}
	ascii, err := idna.Lookup.ToASCII(h)
	if err != nil || ascii == "" || len(ascii) > 253 {
		return "", false
	}
	for label := range strings.SplitSeq(ascii, ".") {
		if label == "" || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' ||
			strings.ContainsFunc(label, func(r rune) bool { return (r < 'a' || r > 'z') && (r < '0' || r > '9') && r != '-' }) {
			return "", false
		}
	}
	return ascii, true
}

func (a AllowedHosts) list() []string {
	if len(a.hosts) == 0 {
		return []string{defaultClientHost}
	}
	return a.hosts
}

// Strings is the list for the log: the hosts, or "*".
func (a AllowedHosts) Strings() []string {
	if a.any {
		return []string{"*"}
	}
	return slices.Clone(a.list())
}

func (a AllowedHosts) allowsHost(h string) bool {
	h, ok := normalHost(h)
	return ok && slices.Contains(a.list(), h)
}

// allowsClient reports whether a client ID may be looked up at all: with a list, only a
// metadata document URL on a listed host. Nothing is fetched to decide this.
func (a AllowedHosts) allowsClient(id string) bool {
	if a.any {
		return true
	}
	u, err := url.Parse(id)
	return err == nil && isCIMD(id) && u.User == nil && a.allowsHost(u.Hostname())
}

// allowsRedirects reports whether every redirect URI is on a listed host or a loopback one.
func (a AllowedHosts) allowsRedirects(uris []string) bool {
	if a.any {
		return true
	}
	for _, raw := range uris {
		u, err := url.Parse(raw)
		if err != nil || u.Host == "" || u.User != nil {
			return false
		}
		if !isLoopbackHost(u.Hostname()) && !a.allowsHost(u.Hostname()) {
			return false
		}
	}
	return true
}

// refusal is the one sentence a refused client is told (FR-183).
func (a AllowedHosts) refusal() string {
	if l := a.list(); len(l) != 1 || l[0] != defaultClientHost {
		return "This relay only accepts apps from " + strings.Join(l, ", ") + "."
	}
	return "This relay only accepts Claude's apps."
}

// errClientRefused marks a lookup refused by the list. zitadel/oidc wraps some failed client
// lookups in an invalid_client error of its own, without our description, and keeps ours only
// as the wrapped cause; the token handler finds this mark there and answers with the sentence
// (told).
var errClientRefused = errors.New("client refused by the list of allowed client hosts")

func (a AllowedHosts) refuse() *oidc.Error {
	return oidc.ErrInvalidClient().WithDescription("%s", a.refusal()).WithParent(errClientRefused)
}

// told puts the refusal sentence back on an error made from a refused lookup.
func (a AllowedHosts) told(err error) error {
	if errors.Is(err, errClientRefused) {
		return a.refuse()
	}
	return err
}

// keeps reports whether a stored client may stay: its ID passes, it wasn't registered on
// request, and a cached document's redirect URIs pass.
func (a AllowedHosts) keeps(c store.OAuthClient) bool {
	if a.any {
		return true
	}
	if c.Kind == "dcr" || !a.allowsClient(c.ID) {
		return false
	}
	if c.Kind != "cimd" {
		return true // a code or token whose client row is gone
	}
	var cached cachedDocument
	return json.Unmarshal(c.MetadataJSON, &cached) == nil && a.allowsRedirects(cached.Document.RedirectURIs)
}

// PurgeRefusedClients deletes every stored client the list refuses, with its codes and tokens,
// and returns how many (FR-184). The relay runs it at start and in the daily purge.
func (s *Server) PurgeRefusedClients(ctx context.Context) (int, error) {
	if s.cfg.AllowedClients.any {
		return 0, nil
	}
	n, err := s.cfg.Store.DeleteClientsExcept(ctx, s.cfg.AllowedClients.keeps)
	if n > 0 {
		s.cfg.Logger.Info("removed stored clients that are no longer allowed, with their codes and tokens",
			"clients", n, "allowed_client_hosts", s.cfg.AllowedClients.Strings())
	}
	return n, err
}

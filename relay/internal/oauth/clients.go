package oauth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/ory/fosite"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Scopes this relay grants (contracts/mcp-surface.md).
var supportedScopes = []string{"mcp", "offline_access"}

const (
	cimdMaxAge   = store.MaxClientDocumentAge // a cached document is fresh for a day at most
	cimdMaxBytes = 64 << 10
	// cimdStaleFor is how long past its freshness a cached document still serves when a new
	// fetch fails, so an outage of the client's metadata host doesn't cut its users off.
	cimdStaleFor = 7 * 24 * time.Hour
	// cimdFailureAge is how long a URL whose fetch failed is not fetched again.
	cimdFailureAge = 5 * time.Minute
	// cimdMaxClients caps the cached documents that no code or token refers to.
	cimdMaxClients = 1000
	// cimdMaxFailures caps the remembered failures (32 bytes and a time each).
	cimdMaxFailures = 4096
)

// cimdMinAge is the least time a fetched document is cached, whatever its host's Cache-Control
// says: a no-store document would otherwise be fetched on every token and /mcp request. A
// variable so a test can turn it off.
var cimdMinAge = 5 * time.Minute

// errDocumentUnavailable is all a caller learns when a metadata document can't be used; the
// reason (which may name internal hosts and addresses) goes to the log.
var errDocumentUnavailable = errors.New("client metadata document unavailable")

// clientMetadata is the part of a CIMD document or DCR request the relay uses.
type clientMetadata struct {
	ClientID                string   `json:"client_id,omitempty"`
	ClientName              string   `json:"client_name,omitempty"`
	ClientURI               string   `json:"client_uri,omitempty"`
	LogoURI                 string   `json:"logo_uri,omitempty"`
	RedirectURIs            []string `json:"redirect_uris"`
	TokenEndpointAuthMethod string   `json:"token_endpoint_auth_method,omitempty"`
	GrantTypes              []string `json:"grant_types,omitempty"`
	ResponseTypes           []string `json:"response_types,omitempty"`
	Scope                   string   `json:"scope,omitempty"`
}

// cachedDocument wraps a CIMD document with its cache expiry.
type cachedDocument struct {
	Document   clientMetadata `json:"document"`
	CacheUntil time.Time      `json:"cache_until"`
}

// client is a fosite client plus what the consent page shows.
type client struct {
	*fosite.DefaultOpenIDConnectClient
	Name string
}

type clients struct {
	st   *store.Store
	http *http.Client
	now  func() time.Time
	log  *slog.Logger
	// allowed is the operator's list of client hosts (FR-180); see allowed.go.
	allowed AllowedHosts

	mu     sync.Mutex
	failed map[[sha256.Size]byte]time.Time // hash of a document URL → when its fetch last failed
}

// failedRecently reports whether the URL's last fetch failed within cimdFailureAge.
func (c *clients) failedRecently(id string, now time.Time) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	at, ok := c.failed[sha256.Sum256([]byte(id))]
	return ok && now.Sub(at) < cimdFailureAge
}

// noteFailure remembers a failed fetch. The table is bounded: when full, expired entries go; if
// none has expired, this failure is simply not remembered.
func (c *clients) noteFailure(id string, now time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.failed) >= cimdMaxFailures {
		for k, at := range c.failed {
			if now.Sub(at) >= cimdFailureAge {
				delete(c.failed, k)
			}
		}
		if len(c.failed) >= cimdMaxFailures {
			return
		}
	}
	c.failed[sha256.Sum256([]byte(id))] = now
}

func (c *clients) clearFailure(id string) {
	c.mu.Lock()
	delete(c.failed, sha256.Sum256([]byte(id)))
	c.mu.Unlock()
}

// requestedRedirectKey carries the redirect_uri of the authorize request into client lookup,
// so a localhost URI on a different port can match (fosite ignores ports only for IP literals).
type requestedRedirectKey struct{}

func withRequestedRedirect(ctx context.Context, uri string) context.Context {
	return context.WithValue(ctx, requestedRedirectKey{}, uri)
}

func (c *clients) get(ctx context.Context, id string) (*client, error) {
	var md clientMetadata
	var secretHash []byte
	// First of all, before the cache and before any fetch: a client the operator's list doesn't
	// allow is refused without a request to its host (FR-183).
	if !c.allowed.allowsClient(id) {
		return nil, c.allowed.refuse()
	}
	if isCIMD(id) {
		doc, err := c.cimd(ctx, id)
		if err != nil {
			// A fixed sentence: the Go error can name internal hosts and addresses (logged in cimd).
			return nil, fosite.ErrInvalidClient.WithHint("The client metadata document could not be fetched or is not valid.")
		}
		// Checked on every lookup, so a document cached under a wider list is covered (FR-181).
		if !c.allowed.allowsRedirects(doc.RedirectURIs) {
			return nil, c.allowed.refuse()
		}
		md = doc
	} else {
		row, err := c.st.OAuthClient(ctx, id)
		if errors.Is(err, store.ErrNotFound) || (err == nil && row.Kind != "dcr") {
			return nil, fosite.ErrNotFound
		}
		if err != nil {
			return nil, err
		}
		if err := json.Unmarshal(row.MetadataJSON, &md); err != nil {
			return nil, err
		}
		secretHash = row.SecretHash
	}
	method := md.TokenEndpointAuthMethod
	if method == "" {
		method = "none"
	}
	redirects := slices.Clone(md.RedirectURIs)
	if req, ok := ctx.Value(requestedRedirectKey{}).(string); ok && matchesLocalhost(req, redirects) {
		redirects = append(redirects, req)
	}
	return &client{
		DefaultOpenIDConnectClient: &fosite.DefaultOpenIDConnectClient{
			DefaultClient: &fosite.DefaultClient{
				ID: id, Secret: secretHash, RedirectURIs: redirects,
				GrantTypes:    []string{"authorization_code", "refresh_token"},
				ResponseTypes: []string{"code"},
				Scopes:        supportedScopes,
				Public:        method == "none",
			},
			TokenEndpointAuthMethod: method,
		},
		Name: displayName(md, id),
	}, nil
}

func displayName(md clientMetadata, id string) string {
	if md.ClientName != "" {
		return md.ClientName
	}
	for _, raw := range []string{md.ClientURI, id} {
		if u, err := url.Parse(raw); err == nil && u.Host != "" {
			return u.Host
		}
	}
	return "An unnamed app"
}

// matchesLocalhost reports whether uri is http://localhost:<port><path> and a registered URI
// differs from it only in the port (RFC 8252 §7.3).
func matchesLocalhost(uri string, registered []string) bool {
	req, err := url.Parse(uri)
	if err != nil || req.Scheme != "http" || req.Hostname() != "localhost" {
		return false
	}
	for _, r := range registered {
		reg, err := url.Parse(r)
		if err == nil && reg.Scheme == "http" && reg.Hostname() == "localhost" &&
			reg.Path == req.Path && reg.RawQuery == req.RawQuery {
			return true
		}
	}
	return false
}

func isCIMD(id string) bool {
	u, err := url.Parse(id)
	return err == nil && u.Scheme == "https" && u.Host != "" && u.Path != "" && u.Path != "/"
}

// cimd returns a client metadata document: the cached copy while it is fresh (five minutes to a
// day), otherwise a new fetch. A failed fetch is remembered for cimdFailureAge, during which the
// URL is not fetched again, and the last good copy keeps serving for cimdStaleFor past its
// freshness. Any failure is errDocumentUnavailable; the reason is logged.
func (c *clients) cimd(ctx context.Context, id string) (clientMetadata, error) {
	now := c.now()
	var stale *clientMetadata
	if row, err := c.st.OAuthClient(ctx, id); err == nil && row.Kind == "cimd" {
		var cached cachedDocument
		if json.Unmarshal(row.MetadataJSON, &cached) == nil {
			if now.Before(cached.CacheUntil) {
				return cached.Document, nil
			}
			if now.Before(cached.CacheUntil.Add(cimdStaleFor)) {
				stale = &cached.Document
			}
		}
	}
	unavailable := func() (clientMetadata, error) {
		if stale != nil {
			return *stale, nil
		}
		return clientMetadata{}, errDocumentUnavailable
	}
	if c.failedRecently(id, now) {
		return unavailable()
	}
	doc, maxAge, err := c.fetch(ctx, id)
	if err != nil {
		c.noteFailure(id, now)
		c.log.Warn("client metadata document not usable", "client_id", truncateID(id), "err", err, "stale_copy_used", stale != nil)
		return unavailable()
	}
	c.clearFailure(id)
	data, err := json.Marshal(cachedDocument{Document: doc, CacheUntil: now.Add(maxAge)})
	if err != nil {
		return clientMetadata{}, err
	}
	err = c.st.PutCachedClient(ctx, store.OAuthClient{ID: id, Kind: "cimd", MetadataJSON: data, CreatedAt: now, FetchedAt: now}, cimdMaxClients)
	return doc, err
}

// truncateID keeps a client-chosen URL short in the log.
func truncateID(id string) string {
	if len(id) > 200 {
		return id[:200] + "..."
	}
	return id
}

func (c *clients) fetch(ctx context.Context, id string) (clientMetadata, time.Duration, error) {
	// Not tied to the request: a caller that goes away mid-fetch must not make the fetch fail
	// and be remembered as a failure of the document.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, id, nil)
	if err != nil {
		return clientMetadata{}, 0, err
	}
	req.Header.Set("Accept", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return clientMetadata{}, 0, err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return clientMetadata{}, 0, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, cimdMaxBytes+1))
	if err != nil {
		return clientMetadata{}, 0, err
	}
	if len(body) > cimdMaxBytes {
		return clientMetadata{}, 0, errors.New("document too large")
	}
	var doc clientMetadata
	if err := json.Unmarshal(body, &doc); err != nil {
		return clientMetadata{}, 0, err
	}
	if doc.ClientID != id {
		return clientMetadata{}, 0, errors.New("client_id does not match the document URL")
	}
	if doc.TokenEndpointAuthMethod != "" && doc.TokenEndpointAuthMethod != "none" {
		return clientMetadata{}, 0, errors.New("only token_endpoint_auth_method none is supported for metadata documents")
	}
	if err := validRedirects(doc.RedirectURIs); err != nil {
		return clientMetadata{}, 0, err
	}
	return doc, cacheMaxAge(resp.Header.Get("Cache-Control")), nil
}

// cacheMaxAge honors Cache-Control max-age between cimdMinAge and 24 hours; no-store and
// no-cache mean cimdMinAge.
func cacheMaxAge(header string) time.Duration {
	for d := range strings.SplitSeq(header, ",") {
		d = strings.TrimSpace(strings.ToLower(d))
		if d == "no-store" || d == "no-cache" {
			return cimdMinAge
		}
		if v, ok := strings.CutPrefix(d, "max-age="); ok {
			if n, err := strconv.ParseInt(v, 10, 64); err == nil && n >= 0 {
				// Clamped in seconds, before the number becomes a Duration it could overflow.
				n = min(max(n, int64(cimdMinAge/time.Second)), int64(cimdMaxAge/time.Second))
				return time.Duration(n) * time.Second
			}
		}
	}
	return cimdMaxAge
}

// validRedirects requires https URIs, or http on a loopback host, without fragments.
func validRedirects(uris []string) error {
	if len(uris) == 0 {
		return errors.New("redirect_uris is required")
	}
	for _, raw := range uris {
		u, err := url.Parse(raw)
		if err != nil || u.Host == "" || u.Fragment != "" {
			return fmt.Errorf("invalid redirect URI %q", raw)
		}
		switch {
		case u.Scheme == "https":
		case u.Scheme == "http" && isLoopbackHost(u.Hostname()):
		default:
			return fmt.Errorf("redirect URI %q must use https (http only on localhost)", raw)
		}
	}
	return nil
}

func isLoopbackHost(h string) bool {
	if h == "localhost" {
		return true
	}
	ip := net.ParseIP(h)
	return ip != nil && ip.IsLoopback()
}

// publicOnlyDialer refuses connections to any address that isn't global unicast (fetchableAddr),
// so a metadata document URL cannot be used to probe the relay's own or any internal network.
func publicOnlyDialer() *net.Dialer {
	return &net.Dialer{
		Timeout: 5 * time.Second,
		Control: func(_, address string, _ syscall.RawConn) error {
			host, _, err := net.SplitHostPort(address)
			if err != nil {
				return err
			}
			ip, err := netip.ParseAddr(host)
			if err != nil || !fetchableAddr(ip) {
				return fmt.Errorf("refusing to fetch client metadata from %s", host)
			}
			return nil
		},
	}
}

// Every range in the IANA IPv4 Special-Purpose Address Registry, refused whole (even the few
// entries marked globally reachable, such as anycast and AS112: no client document lives there).
var specialIPv4 = prefixes(
	"0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
	"192.0.0.0/24", "192.0.2.0/24", "192.31.196.0/24", "192.52.193.0/24", "192.88.99.0/24",
	"192.168.0.0/16", "192.175.48.0/24", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24",
	"224.0.0.0/4", "240.0.0.0/4", // multicast; reserved, including 255.255.255.255
)

var (
	// Only 2000::/3 is global unicast; this alone refuses ::/8 (loopback, unspecified, IPv4-
	// compatible and -translated forms), 64:ff9b:1::/48, 100::/64, 5f00::/16, fc00::/7, fe80::/10,
	// fec0::/10, and ff00::/8.
	globalIPv6 = netip.MustParsePrefix("2000::/3")
	// Special-purpose ranges inside 2000::/3: IETF protocol assignments (Teredo, benchmarking,
	// ORCHID...), documentation, and 6to4 (which embeds any IPv4 address).
	specialIPv6 = prefixes("2001::/23", "2001:db8::/32", "2002::/16", "3fff::/20")
	// NAT64's well-known prefix embeds an IPv4 address; that address decides.
	nat64 = netip.MustParsePrefix("64:ff9b::/96")
)

func prefixes(s ...string) []netip.Prefix {
	p := make([]netip.Prefix, len(s))
	for i, x := range s {
		p[i] = netip.MustParsePrefix(x)
	}
	return p
}

// fetchableAddr reports whether a is a globally routable unicast address, outside every IANA
// special-purpose range (threat model: a metadata URL must not reach internal networks).
func fetchableAddr(a netip.Addr) bool {
	a = a.WithZone("").Unmap()
	if a.Is6() && nat64.Contains(a) {
		b := a.As16()
		a = netip.AddrFrom4([4]byte{b[12], b[13], b[14], b[15]})
	}
	inAny := func(ps []netip.Prefix) bool {
		return slices.ContainsFunc(ps, func(p netip.Prefix) bool { return p.Contains(a) })
	}
	if a.Is4() {
		return !inAny(specialIPv4)
	}
	return globalIPv6.Contains(a) && !inAny(specialIPv6)
}

// registerRequest is an RFC 7591 registration.
type registerResponse struct {
	clientMetadata
	ClientSecret          string `json:"client_secret,omitempty"`
	ClientIDIssuedAt      int64  `json:"client_id_issued_at"`
	ClientSecretExpiresAt int64  `json:"client_secret_expires_at"`
}

// register handles POST /register (RFC 7591).
func (c *clients) register(w http.ResponseWriter, r *http.Request) {
	if !c.allowed.any {
		// FR-182: with a list of client hosts, clients identify themselves with a metadata
		// document; nothing is registered on request.
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusForbidden)
		_ = json.NewEncoder(w).Encode(map[string]string{
			"error":             "access_denied",
			"error_description": c.allowed.refusal() + " Registering a client is turned off; identify the client with a client ID metadata document.",
		})
		return
	}
	var md clientMetadata
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, cimdMaxBytes)).Decode(&md); err != nil {
		registerError(w, "invalid_client_metadata", "The request body is not valid client metadata.")
		return
	}
	if err := validRedirects(md.RedirectURIs); err != nil {
		registerError(w, "invalid_redirect_uri", err.Error())
		return
	}
	switch md.TokenEndpointAuthMethod {
	case "":
		md.TokenEndpointAuthMethod = "client_secret_basic" // RFC 7591 default
	case "none", "client_secret_basic", "client_secret_post":
	default:
		registerError(w, "invalid_client_metadata", "Unsupported token_endpoint_auth_method.")
		return
	}
	for _, g := range md.GrantTypes {
		if g != "authorization_code" && g != "refresh_token" {
			registerError(w, "invalid_client_metadata", "Unsupported grant type "+g+".")
			return
		}
	}
	md.ClientID = "cl_" + randomString(16)
	md.GrantTypes = []string{"authorization_code", "refresh_token"}
	md.ResponseTypes = []string{"code"}
	md.Scope = strings.Join(supportedScopes, " ")

	var secret string
	var secretHash []byte
	if md.TokenEndpointAuthMethod != "none" {
		secret = randomString(32)
		h := sha256.Sum256([]byte(secret))
		secretHash = h[:]
	}
	data, err := json.Marshal(md)
	if err != nil {
		http.Error(w, "server error", http.StatusInternalServerError)
		return
	}
	now := c.now()
	if err := c.st.PutOAuthClient(r.Context(), store.OAuthClient{
		ID: md.ClientID, Kind: "dcr", MetadataJSON: data, SecretHash: secretHash, CreatedAt: now,
	}); err != nil {
		http.Error(w, "server error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusCreated)
	// RFC 7591: the secret is returned once, at registration.
	resp := registerResponse{clientMetadata: md, ClientSecret: secret, ClientIDIssuedAt: now.Unix()}
	_ = json.NewEncoder(w).Encode(resp) //nolint:gosec // see above
}

func registerError(w http.ResponseWriter, code, desc string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusBadRequest)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": code, "error_description": desc})
}

func randomString(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b) // never fails (crypto/rand)
	return base64.RawURLEncoding.EncodeToString(b)
}

// sha256Hasher compares client secrets by SHA-256 (they are random, so no slow hash is needed).
type sha256Hasher struct{}

func (sha256Hasher) Compare(_ context.Context, hash, data []byte) error {
	h := sha256.Sum256(data)
	if subtle.ConstantTimeCompare(hash, h[:]) != 1 {
		return errors.New("secret mismatch")
	}
	return nil
}

func (sha256Hasher) Hash(_ context.Context, data []byte) ([]byte, error) {
	h := sha256.Sum256(data)
	return h[:], nil
}

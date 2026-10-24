// Package limit holds the relay's abuse limits: keyed token buckets (per IP address, per email
// address, per user) and the client IP address behind a trusted reverse proxy. Limits are in
// memory: a restart resets them, which is acceptable for limits that only slow abuse down.
package limit

import (
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"time"

	"golang.org/x/time/rate"
)

// Keyed is a set of token buckets, one per key, each refilling at the same rate.
type Keyed struct {
	every time.Duration
	burst int
	now   func() time.Time

	mu      sync.Mutex
	buckets map[string]*bucket
	swept   time.Time
}

type bucket struct {
	lim  *rate.Limiter
	seen time.Time
}

// NewKeyed allows burst events per key at once, then one every interval.
func NewKeyed(burst int, every time.Duration) *Keyed {
	return &Keyed{every: every, burst: burst, now: time.Now, buckets: map[string]*bucket{}}
}

// Allow takes one token from key's bucket and reports whether one was there.
func (k *Keyed) Allow(key string) bool { return k.AllowAt(key, k.now()) }

// AllowAt is Allow at a given time, for callers with their own clock.
func (k *Keyed) AllowAt(key string, now time.Time) bool {
	k.mu.Lock()
	defer k.mu.Unlock()
	b, ok := k.buckets[key]
	if !ok {
		b = &bucket{lim: rate.NewLimiter(rate.Every(k.every), k.burst)}
		k.buckets[key] = b
	}
	b.seen = now
	allowed := b.lim.AllowN(now, 1)
	// A bucket idle long enough to be full again carries no state; drop it so memory stays bounded.
	full := k.every * time.Duration(k.burst)
	if now.Sub(k.swept) > full {
		for key, b := range k.buckets {
			if now.Sub(b.seen) > full {
				delete(k.buckets, key)
			}
		}
		k.swept = now
	}
	return allowed
}

// TrustedProxies are the reverse proxies, besides one on this machine, whose X-Forwarded-For
// header the relay believes (FR-082, the TRUSTED_PROXIES setting). Empty means loopback only.
type TrustedProxies []netip.Prefix

// ParseTrustedProxies reads a comma-separated list of IP addresses and CIDR ranges.
func ParseTrustedProxies(s string) (TrustedProxies, error) {
	var p TrustedProxies
	for f := range strings.SplitSeq(s, ",") {
		if f = strings.TrimSpace(f); f == "" {
			continue
		}
		pre, err := netip.ParsePrefix(f)
		if err != nil {
			a, aerr := netip.ParseAddr(f)
			if aerr != nil {
				return nil, fmt.Errorf("%q is not an IP address or CIDR range", f)
			}
			a = a.Unmap()
			pre = netip.PrefixFrom(a, a.BitLen())
		}
		p = append(p, pre.Masked())
	}
	return p, nil
}

// Strings lists the ranges in CIDR form, for logs and tests.
func (p TrustedProxies) Strings() []string {
	s := make([]string, len(p))
	for i, x := range p {
		s[i] = x.String()
	}
	return s
}

func (p TrustedProxies) trusts(peer netip.Addr) bool {
	if peer.IsLoopback() {
		return true
	}
	for _, pre := range p {
		if pre.Contains(peer) {
			return true
		}
	}
	return false
}

// ClientIP is the address the request came from. When the direct peer is a proxy on this machine
// or one listed in p, the client is the rightmost X-Forwarded-For entry, the one that proxy added.
// Any other peer can't spoof its address: its X-Forwarded-For is ignored. Being on a private
// network is not enough: with `docker run -p`, internet clients can arrive from the Docker bridge
// gateway's private address.
func (p TrustedProxies) ClientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	peer, err := netip.ParseAddr(host)
	if err != nil {
		return host
	}
	peer = peer.Unmap()
	if p.trusts(peer) {
		if xff := r.Header.Values("X-Forwarded-For"); len(xff) > 0 {
			parts := strings.Split(xff[len(xff)-1], ",")
			if a, err := netip.ParseAddr(strings.TrimSpace(parts[len(parts)-1])); err == nil {
				return bucketKey(a.Unmap())
			}
		}
	}
	return bucketKey(peer)
}

// bucketKey groups IPv6 clients by /64, the usual allocation to one customer, so rotating
// addresses inside one network doesn't escape the limit.
func bucketKey(a netip.Addr) string {
	if a.Is6() {
		p, _ := a.Prefix(64)
		return p.String()
	}
	return a.String()
}

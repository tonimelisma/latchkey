// Package limit holds the relay's abuse limits: keyed token buckets (per IP address, per email
// address, per user) and the client IP address behind a local reverse proxy. Limits are in memory:
// a restart resets them, which is acceptable for limits that only slow abuse down.
package limit

import (
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

// ClientIP is the address the request came from. When the direct peer is a proxy on this machine
// or a private network (Caddy, Traefik, nginx, a hosting platform's router), the client is the
// rightmost X-Forwarded-For entry, the one that proxy added. A direct public peer can't spoof it:
// its X-Forwarded-For is ignored.
func ClientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	peer, err := netip.ParseAddr(host)
	if err != nil {
		return host
	}
	peer = peer.Unmap()
	if peer.IsLoopback() || peer.IsPrivate() {
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

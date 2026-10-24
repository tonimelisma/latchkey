package limit

import (
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestKeyedAllowsBurstThenRefills(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	k := NewKeyed(3, time.Minute)
	k.now = func() time.Time { return now }
	for range 3 {
		assert.True(t, k.Allow("a"))
	}
	assert.False(t, k.Allow("a"), "burst used up")
	assert.True(t, k.Allow("b"), "keys are independent")
	now = now.Add(time.Minute)
	assert.True(t, k.Allow("a"), "one token back after one interval")
	assert.False(t, k.Allow("a"))
}

func TestKeyedForgetsIdleKeys(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	k := NewKeyed(2, time.Second)
	k.now = func() time.Time { return now }
	for i := range 100 {
		k.Allow(string(rune('a' + i)))
	}
	now = now.Add(time.Hour)
	k.Allow("z")
	assert.Len(t, k.buckets, 1)
}

func TestClientIP(t *testing.T) {
	trusted, err := ParseTrustedProxies("172.18.0.0/16, 10.1.2.3")
	require.NoError(t, err)
	cases := []struct {
		name, remote, xff, want string
		proxies                 TrustedProxies
	}{
		{"direct public peer", "203.0.113.9:4000", "", "203.0.113.9", nil},
		{"public peer can't spoof", "203.0.113.9:4000", "198.51.100.1", "203.0.113.9", trusted},
		{"local proxy", "127.0.0.1:4000", "198.51.100.1", "198.51.100.1", nil},
		{"ipv6 local proxy", "[::1]:4000", "198.51.100.1", "198.51.100.1", nil},
		{"private peer not trusted by default", "172.17.0.1:4000", "198.51.100.1", "172.17.0.1", nil},
		{"private peer outside the trusted list", "172.17.0.1:4000", "198.51.100.1", "172.17.0.1", trusted},
		{"listed docker network proxy", "172.18.0.2:4000", "10.0.0.1, 198.51.100.1", "198.51.100.1", trusted},
		{"listed single address, rightmost entry wins", "10.1.2.3:4000", "6.6.6.6, 198.51.100.1", "198.51.100.1", trusted},
		{"neighbour of a listed address", "10.1.2.4:4000", "198.51.100.1", "10.1.2.4", trusted},
		{"proxy without header", "172.18.0.2:4000", "", "172.18.0.2", trusted},
		{"garbage header", "127.0.0.1:4000", "not-an-ip", "127.0.0.1", nil},
		{"ipv6 grouped by /64", "[2001:db8:1:2:3:4:5:6]:4000", "", "2001:db8:1:2::/64", nil},
		{"ipv4-mapped", "[::ffff:203.0.113.9]:4000", "", "203.0.113.9", nil},
		{"ipv4-mapped listed proxy", "[::ffff:172.18.0.2]:4000", "198.51.100.1", "198.51.100.1", trusted},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := httptest.NewRequestWithContext(t.Context(), "GET", "/", nil)
			r.RemoteAddr = c.remote
			if c.xff != "" {
				r.Header.Set("X-Forwarded-For", c.xff)
			}
			assert.Equal(t, c.want, c.proxies.ClientIP(r))
		})
	}
}

func TestParseTrustedProxies(t *testing.T) {
	p, err := ParseTrustedProxies("")
	require.NoError(t, err)
	assert.Empty(t, p)
	p, err = ParseTrustedProxies(" 172.18.0.0/16 ,, fd00::/8, 192.0.2.7 ")
	require.NoError(t, err)
	assert.Equal(t, []string{"172.18.0.0/16", "fd00::/8", "192.0.2.7/32"}, p.Strings())
	for _, bad := range []string{"not-an-ip", "172.18.0.0/40", "caddy"} {
		_, err := ParseTrustedProxies(bad)
		assert.Error(t, err, bad)
	}
}

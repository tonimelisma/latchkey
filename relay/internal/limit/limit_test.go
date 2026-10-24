package limit

import (
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
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
	cases := []struct {
		name, remote, xff, want string
	}{
		{"direct public peer", "203.0.113.9:4000", "", "203.0.113.9"},
		{"public peer can't spoof", "203.0.113.9:4000", "198.51.100.1", "203.0.113.9"},
		{"local proxy", "127.0.0.1:4000", "198.51.100.1", "198.51.100.1"},
		{"docker network proxy", "172.18.0.2:4000", "10.0.0.1, 198.51.100.1", "198.51.100.1"},
		{"rightmost entry wins", "10.1.2.3:4000", "6.6.6.6, 198.51.100.1", "198.51.100.1"},
		{"proxy without header", "172.18.0.2:4000", "", "172.18.0.2"},
		{"garbage header", "127.0.0.1:4000", "not-an-ip", "127.0.0.1"},
		{"ipv6 grouped by /64", "[2001:db8:1:2:3:4:5:6]:4000", "", "2001:db8:1:2::/64"},
		{"ipv4-mapped", "[::ffff:203.0.113.9]:4000", "", "203.0.113.9"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := httptest.NewRequestWithContext(t.Context(), "GET", "/", nil)
			r.RemoteAddr = c.remote
			if c.xff != "" {
				r.Header.Set("X-Forwarded-For", c.xff)
			}
			assert.Equal(t, c.want, ClientIP(r))
		})
	}
}

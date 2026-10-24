package oauth

import (
	"net/netip"
	"testing"

	"github.com/stretchr/testify/assert"
)

// The client-metadata fetch may reach only globally routable unicast addresses: everything in the
// IANA special-purpose registries is refused, IPv4 and IPv6, mapped and translated forms included.
func TestFetchableAddress(t *testing.T) {
	refused := []string{
		// RFC 1918, loopback, link-local, unspecified, multicast, broadcast
		"10.1.2.3", "172.16.0.1", "192.168.1.1", "127.0.0.1", "169.254.169.254", "0.0.0.0", "0.1.2.3",
		"224.0.0.1", "255.255.255.255",
		// non-RFC 1918 special-purpose IPv4
		"100.64.0.7", "100.127.255.255", // shared address space (CGNAT, Tailscale)
		"192.0.0.8", "192.0.0.9", // IETF protocol assignments
		"192.0.2.1", "198.51.100.1", "203.0.113.1", // documentation
		"198.18.0.1", "198.19.255.255", // benchmarking
		"192.88.99.1", "192.31.196.1", "192.52.193.1", "192.175.48.1",
		"240.0.0.1", // reserved
		// IPv6
		"::1", "::", "fc00::1", "fd12:3456::1", "fe80::1", "fec0::1", "ff02::1",
		"100::1",                             // discard-only
		"2001::1", "2001:2::1", "2001:10::1", // IETF assignments: Teredo, benchmarking, ORCHID
		"2001:db8::1", "3fff::1", // documentation
		"2002:a00:1::1", // 6to4
		"5f00::1",       // SRv6 SIDs
		"64:ff9b:1::1",  // local-use IPv4/IPv6 translation
		// IPv4 hidden in IPv6
		"::ffff:10.0.0.1", "::ffff:127.0.0.1", "::ffff:100.64.0.1", // mapped
		"64:ff9b::a00:1", "64:ff9b::7f00:1", "64:ff9b::6440:1", // NAT64 of 10.0.0.1, 127.0.0.1, 100.64.0.1
		"::ffff:0:a00:1", // IPv4-translated
		"::a00:1",        // IPv4-compatible (deprecated)
	}
	allowed := []string{
		"8.8.8.8", "1.1.1.1", "100.63.255.255", "100.128.0.1", "198.20.0.1", "192.0.1.1",
		"2606:4700:4700::1111", "2a00:1450:4001::1",
		"::ffff:8.8.8.8", "64:ff9b::808:808", // public IPv4, mapped and through NAT64
	}
	for _, s := range refused {
		assert.False(t, fetchableAddr(netip.MustParseAddr(s)), "must refuse %s", s)
	}
	for _, s := range allowed {
		assert.True(t, fetchableAddr(netip.MustParseAddr(s)), "must allow %s", s)
	}
}

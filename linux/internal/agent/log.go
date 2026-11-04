package agent

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"regexp"
	"strings"
	"syscall"
)

// What Claude may see of an error (FR-1053, FR-1056; research.md "Where the server's log lines
// come from"). Raw errors carry the relay's address, its IP, URLs, and file paths, so the public
// words name the kind of failure, and anything else is scrubbed (Scrub).

// describe is an error in words without private details.
func describe(err error, relay string) string {
	var ce closeError
	var dns *net.DNSError
	var unknownCA x509.UnknownAuthorityError
	var hostname x509.HostnameError
	var invalid x509.CertificateInvalidError
	var verify *tls.CertificateVerificationError
	switch {
	case errors.As(err, &ce):
		return fmt.Sprintf("the relay closed the connection (%d %s)", int(ce.code), Scrub(ce.reason, relay))
	case errors.Is(err, errReconnect):
		return "the name changed"
	case errors.Is(err, context.DeadlineExceeded):
		return "the relay didn't answer in time"
	case errors.As(err, &dns):
		return "the relay's name couldn't be looked up"
	case errors.Is(err, syscall.ECONNREFUSED):
		return "the relay refused the connection"
	case errors.Is(err, syscall.ECONNRESET):
		return "the connection was reset"
	case errors.Is(err, syscall.ENETUNREACH), errors.Is(err, syscall.EHOSTUNREACH):
		return "the network can't reach the relay"
	case errors.As(err, &unknownCA), errors.As(err, &hostname), errors.As(err, &invalid), errors.As(err, &verify):
		return "the relay's certificate wasn't accepted"
	case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF), errors.Is(err, net.ErrClosed):
		return "the connection dropped"
	}
	return Scrub(err.Error(), relay)
}

var (
	anyURL  = regexp.MustCompile(`[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"'<>]+`)
	ipv4    = regexp.MustCompile(`\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b`)
	ipv6    = regexp.MustCompile(`\[[0-9a-fA-F:.%]+\](?::\d+)?|\b(?:[0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}\b`)
	absPath = regexp.MustCompile(`(^|[\s"'(=])/[^\s"'):]+`)
)

// Scrub replaces the relay's address and host, any URL, IP address, and absolute path in s with
// words.
func Scrub(s, relay string) string {
	if relay != "" {
		s = strings.ReplaceAll(s, relay, "the relay")
		if u, err := url.Parse(relay); err == nil && u.Hostname() != "" {
			s = strings.ReplaceAll(s, u.Host, "the relay")
			s = strings.ReplaceAll(s, u.Hostname(), "the relay")
		}
	}
	s = anyURL.ReplaceAllString(s, "an address")
	s = ipv6.ReplaceAllStringFunc(s, func(m string) string {
		if strings.Count(m, ":") < 2 || strings.Trim(m, ":") == "" {
			return m // a time like 12:30 or a lone colon
		}
		return "an address"
	})
	s = ipv4.ReplaceAllString(s, "an address")
	return absPath.ReplaceAllString(s, "${1}a file")
}

// The steps before a connection, for "not connecting".
const (
	stepSettings = "settings"
	stepKey      = "key"
)

// notConnecting names the step that failed, never the error's path.
func notConnecting(step string, err error) string {
	switch {
	case errors.Is(err, ErrNotPaired):
		return "Not connecting: this server isn't paired yet (latchkey install pairs it)"
	case step == stepKey:
		return "Not connecting: the device key couldn't be read"
	default:
		return "Not connecting: the settings couldn't be read"
	}
}

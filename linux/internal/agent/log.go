package agent

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"reflect"
	"syscall"
)

// What Claude may see of an error (FR-1053, FR-1056; research.md "Where the server's log lines
// come from"). Raw errors carry the relay's address, its IP, URLs, host and user names, paths,
// and whatever else a library put in them, so public words are never built from an error's
// message (security review 2026-11-04): they name the kind of failure, and an unrecognized error
// is a fixed phrase naming only its Go type.

// describe is a connection error in words without private details.
func describe(err error) string {
	var ce closeError
	switch {
	case errors.As(err, &ce):
		return fmt.Sprintf("the relay closed the connection (%d)", int(ce.code))
	case errors.Is(err, errReconnect):
		return "the name changed"
	case errors.Is(err, context.DeadlineExceeded):
		return "the relay didn't answer in time"
	case isDNS(err):
		return "the relay's name couldn't be looked up"
	case errors.Is(err, syscall.ECONNREFUSED):
		return "the relay refused the connection"
	case errors.Is(err, syscall.ECONNRESET):
		return "the connection was reset"
	case errors.Is(err, syscall.ENETUNREACH), errors.Is(err, syscall.EHOSTUNREACH):
		return "the network can't reach the relay"
	case isCertificate(err):
		return "the relay's certificate wasn't accepted"
	case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF), errors.Is(err, net.ErrClosed):
		return "the connection dropped"
	}
	return unexpected(err)
}

// DescribeUpdate is an update check's error in words without private details.
func DescribeUpdate(err error) string {
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return "GitHub didn't answer in time"
	case isDNS(err):
		return "GitHub's name couldn't be looked up"
	case errors.Is(err, syscall.ECONNREFUSED), errors.Is(err, syscall.ECONNRESET),
		errors.Is(err, syscall.ENETUNREACH), errors.Is(err, syscall.EHOSTUNREACH):
		return "the network can't reach GitHub"
	case isCertificate(err):
		return "GitHub's certificate wasn't accepted"
	case errors.Is(err, fs.ErrPermission):
		return "permission denied"
	case errors.Is(err, syscall.ENOSPC):
		return "the disk is full"
	}
	return unexpected(err)
}

func isDNS(err error) bool {
	var dns *net.DNSError
	return errors.As(err, &dns)
}

func isCertificate(err error) bool {
	var unknownCA x509.UnknownAuthorityError
	var hostname x509.HostnameError
	var invalid x509.CertificateInvalidError
	var verify *tls.CertificateVerificationError
	return errors.As(err, &unknownCA) || errors.As(err, &hostname) || errors.As(err, &invalid) || errors.As(err, &verify)
}

// wrappers are fmt's wrapping types: they say nothing about the failure.
var wrappers = map[string]bool{"*fmt.wrapError": true, "*fmt.wrapErrors": true, "*errors.joinError": true}

// unexpected names only the error's type: the first in its chain that isn't one of fmt's
// wrappers, else the innermost.
func unexpected(err error) string {
	name := reflect.TypeOf(err).String()
	for e := err; e != nil; e = errors.Unwrap(e) {
		name = reflect.TypeOf(e).String()
		if !wrappers[name] {
			break
		}
	}
	return "an unexpected error (" + name + ")"
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

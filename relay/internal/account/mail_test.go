package account

import (
	"bufio"
	"context"
	"net"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// plainSMTP is a minimal SMTP server that never offers STARTTLS, like an on-path attacker that
// strips it from the server's reply. It counts the messages it receives.
func plainSMTP(t *testing.T) (addr string, received *atomic.Int32) {
	t.Helper()
	var lc net.ListenConfig
	ln, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	require.NoError(t, err)
	t.Cleanup(func() { _ = ln.Close() })
	received = &atomic.Int32{}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer func() { _ = conn.Close() }()
				r := bufio.NewReader(conn)
				say := func(s string) { _, _ = conn.Write([]byte(s + "\r\n")) }
				say("220 fake ESMTP")
				for {
					line, err := r.ReadString('\n')
					if err != nil {
						return
					}
					cmd := strings.ToUpper(strings.TrimSpace(line))
					switch {
					case strings.HasPrefix(cmd, "EHLO"):
						say("250-fake")
						say("250 8BITMIME")
					case cmd == "DATA":
						say("354 go ahead")
						for {
							l, err := r.ReadString('\n')
							if err != nil {
								return
							}
							if l == ".\r\n" {
								break
							}
						}
						received.Add(1)
						say("250 queued")
					case cmd == "QUIT":
						say("221 bye")
						return
					default:
						say("250 ok")
					}
				}
			}()
		}
	}()
	return ln.Addr().String(), received
}

func TestSMTPMailerRefusesPlainTextToRemoteServer(t *testing.T) {
	addr, received := plainSMTP(t)
	m := NewSMTPMailer(SMTPConfig{Host: "smtp.example.com", Port: 587, From: "relay@example.com"})
	m.dial = func(ctx context.Context, network, _ string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, network, addr)
	}
	err := m.Send(context.Background(), "owner@example.com", "Your code", "123456")
	require.Error(t, err, "a server that doesn't offer STARTTLS must not get the message")
	assert.Equal(t, int32(0), received.Load())
}

func TestSMTPMailerAllowsPlainTextToLoopback(t *testing.T) {
	addr, received := plainSMTP(t)
	host, port, err := net.SplitHostPort(addr)
	require.NoError(t, err)
	p, err := strconv.Atoi(port)
	require.NoError(t, err)
	m := NewSMTPMailer(SMTPConfig{Host: host, Port: p, From: "relay@example.com"})
	require.NoError(t, m.Send(context.Background(), "owner@example.com", "Your code", "123456"))
	assert.Equal(t, int32(1), received.Load())
}

func TestPlainSMTPAllowed(t *testing.T) {
	for host, want := range map[string]bool{
		"localhost": true, "127.0.0.1": true, "::1": true, "127.1.2.3": true,
		"smtp.example.com": false, "10.0.0.5": false, "192.168.1.1": false, "": false, "localhost.example.com": false,
	} {
		assert.Equal(t, want, plainSMTPAllowed(host), host)
	}
}

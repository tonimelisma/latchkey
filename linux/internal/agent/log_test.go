package agent

import (
	"context"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/linux/internal/activity"
	"github.com/tonimelisma/latchkey/linux/internal/config"
	"github.com/tonimelisma/latchkey/linux/internal/files"
	"github.com/tonimelisma/latchkey/linux/internal/shell"
)

const relay = "https://relay.example.net"

// The public words name the kind of failure, never the relay's address, its IP, or a file
// (FR-1053, FR-1056).
func TestDescribeKeepsPrivateDetailsOut(t *testing.T) {
	cases := map[string]error{
		"the relay closed the connection (4002 replaced)": closeError{4002, "replaced"},
		"the relay didn't answer in time":                 fmt.Errorf("failed to WebSocket dial: %w", context.DeadlineExceeded),
		"the relay's name couldn't be looked up":          &net.OpError{Op: "dial", Err: &net.DNSError{Name: "relay.example.net", Err: "no such host"}},
		"the relay refused the connection":                &net.OpError{Op: "dial", Addr: &net.TCPAddr{IP: net.IPv4(10, 1, 2, 3), Port: 443}, Err: os.NewSyscallError("connect", syscall.ECONNREFUSED)},
		"the connection was reset":                        fmt.Errorf("read: %w", syscall.ECONNRESET),
		"the network can't reach the relay":               fmt.Errorf("dial: %w", syscall.ENETUNREACH),
		"the relay's certificate wasn't accepted":         fmt.Errorf("tls: %w", x509.UnknownAuthorityError{}),
		"the connection dropped":                          fmt.Errorf("failed to read frame header: %w", io.ErrUnexpectedEOF),
		"the name changed":                                errReconnect,
	}
	for want, err := range cases {
		assert.Equal(t, want, describe(err, relay), "%v", err)
	}
	other := errors.New(`failed to WebSocket dial: failed to send handshake request: Get "https://relay.example.net/agent/v1": proxy 192.168.1.9:3128 and [2001:db8::1]:443 refused; open /home/toni/.config/latchkey/settings.json: denied`)
	got := describe(other, relay)
	for _, private := range []string{"relay.example.net", "192.168.1.9", "2001:db8", "/home/toni", "settings.json"} {
		assert.NotContains(t, got, private)
	}
	assert.Contains(t, got, "failed to WebSocket dial")
}

func TestScrub(t *testing.T) {
	assert.Equal(t, "GitHub answered 503 at an address", Scrub("GitHub answered 503 at https://api.github.com/repos/x/y/releases", relay))
	assert.Equal(t, "couldn't keep the current version: open a file: permission denied", Scrub("couldn't keep the current version: open /home/toni/.local/lib/latchkey/latchkey.previous: permission denied", relay))
	assert.Equal(t, "lookup the relay: no such host", Scrub("lookup relay.example.net: no such host", relay))
	assert.Equal(t, "up to 1000 lines", Scrub("up to 1000 lines", relay), "plain words stay")
}

func TestNotConnectingNamesTheStep(t *testing.T) {
	assert.Equal(t, "Not connecting: this server isn't paired yet (latchkey install pairs it)", notConnecting(stepSettings, ErrNotPaired))
	assert.Equal(t, "Not connecting: the settings couldn't be read", notConnecting(stepSettings, errors.New("open /home/toni/.config/latchkey/settings.json: denied")))
	assert.Equal(t, "Not connecting: the device key couldn't be read", notConnecting(stepKey, errors.New("open /home/toni/.local/share/latchkey/device.key: no such file")))
}

// latchkey_log is offered whatever Shell and Files are (FR-1052).
func TestTheLogToolIsAlwaysOffered(t *testing.T) {
	home := t.TempDir()
	p := config.PathsFor(home, "", "", "")
	log, err := activity.Open(filepath.Join(home, "activity.jsonl"))
	require.NoError(t, err)
	a := &Agent{Paths: p, Version: "0.1.1", Log: log, Shell: shell.New(p), Files: files.New(p)}
	off := a.toolsFor(config.Settings{Shell: config.Off, Files: config.FilesOff})
	assert.Equal(t, []string{"latchkey_log"}, sortedKeys(off))
	on := a.toolsFor(config.Settings{Shell: config.On, Files: config.FilesWrite})
	assert.Contains(t, sortedKeys(on), "latchkey_log")
	assert.Contains(t, sortedKeys(on), "shell_run")
}

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

// The public words name the kind of failure, never the relay's address, its IP, or a file
// (FR-1053, FR-1056); they are never built from an error's message.
func TestDescribeKeepsPrivateDetailsOut(t *testing.T) {
	cases := map[string]error{
		"the relay closed the connection (4002)":  closeError{4002, "replaced by relay.example.net"},
		"the relay didn't answer in time":         fmt.Errorf("failed to WebSocket dial: %w", context.DeadlineExceeded),
		"the relay's name couldn't be looked up":  &net.OpError{Op: "dial", Err: &net.DNSError{Name: "relay.example.net", Err: "no such host"}},
		"the relay refused the connection":        &net.OpError{Op: "dial", Addr: &net.TCPAddr{IP: net.IPv4(10, 1, 2, 3), Port: 443}, Err: os.NewSyscallError("connect", syscall.ECONNREFUSED)},
		"the connection was reset":                fmt.Errorf("read: %w", syscall.ECONNRESET),
		"the network can't reach the relay":       fmt.Errorf("dial: %w", syscall.ENETUNREACH),
		"the relay's certificate wasn't accepted": fmt.Errorf("tls: %w", x509.UnknownAuthorityError{}),
		"the connection dropped":                  fmt.Errorf("failed to read frame header: %w", io.ErrUnexpectedEOF),
		"the name changed":                        errReconnect,
	}
	for want, err := range cases {
		assert.Equal(t, want, describe(err), "%v", err)
	}
}

// oddError is an error type the describers don't know, with private details in its message.
type oddError struct{}

func (oddError) Error() string {
	return "dial homeserver-db: open config/secret.txt as toni: token=sk-abc123 at https://relay.example.net"
}

// An unrecognized error yields only a fixed phrase naming its type, never its message
// (security review 2026-11-04).
func TestUnrecognizedErrorsNameOnlyTheirType(t *testing.T) {
	err := fmt.Errorf("failed to WebSocket dial: %w", oddError{})
	assert.Equal(t, "an unexpected error (agent.oddError)", describe(err))
	assert.Equal(t, "an unexpected error (agent.oddError)", DescribeUpdate(err))
	plain := errors.New(`Get "https://relay.example.net/agent/v1": proxy 192.168.1.9:3128; open ./settings.json as toni: token=abc`)
	assert.Equal(t, "an unexpected error (*errors.errorString)", describe(plain))
	assert.Equal(t, "an unexpected error (*errors.errorString)", DescribeUpdate(fmt.Errorf("couldn't keep the current version: %w", plain)))
}

func TestDescribeUpdate(t *testing.T) {
	assert.Equal(t, "GitHub didn't answer in time", DescribeUpdate(fmt.Errorf("get: %w", context.DeadlineExceeded)))
	assert.Equal(t, "GitHub's name couldn't be looked up", DescribeUpdate(&net.OpError{Op: "dial", Err: &net.DNSError{Name: "api.github.com"}}))
	assert.Equal(t, "the network can't reach GitHub", DescribeUpdate(fmt.Errorf("dial: %w", syscall.ENETUNREACH)))
	assert.Equal(t, "permission denied", DescribeUpdate(&os.PathError{Op: "open", Path: "/home/toni/.local/lib/latchkey/latchkey.previous", Err: os.ErrPermission}))
	assert.Equal(t, "the disk is full", DescribeUpdate(&os.PathError{Op: "write", Path: "/x", Err: syscall.ENOSPC}))
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

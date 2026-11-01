package main

import (
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Podman's Quadlet with Notify=true (spec 009 plan D3) passes NOTIFY_SOCKET; the relay says
// READY=1 when it accepts connections and STOPPING=1 when it shuts down, so an update that
// doesn't start is rolled back.
func TestNotifySystemd(t *testing.T) {
	dir, err := os.MkdirTemp("", "sd") // short: a socket path has at most about 100 bytes
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	path := filepath.Join(dir, "notify")
	conn, err := net.ListenUnixgram("unixgram", &net.UnixAddr{Name: path, Net: "unixgram"})
	require.NoError(t, err)
	t.Cleanup(func() { _ = conn.Close() })
	getenv := func(k string) string {
		if k == "NOTIFY_SOCKET" {
			return path
		}
		return ""
	}

	require.NoError(t, notifySystemd(getenv, "READY=1"))
	buf := make([]byte, 64)
	require.NoError(t, conn.SetReadDeadline(time.Now().Add(2*time.Second)))
	n, err := conn.Read(buf)
	require.NoError(t, err)
	assert.Equal(t, "READY=1", string(buf[:n]))

	require.NoError(t, notifySystemd(func(string) string { return "" }, "READY=1"), "no service manager: nothing to do")
	assert.Error(t, notifySystemd(func(string) string { return filepath.Join(dir, "missing") }, "READY=1"))
}

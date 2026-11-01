package main

import (
	"net"
	"strings"
)

// notifySystemd tells the service manager the relay's state ("READY=1", "STOPPING=1") when it
// asked to be told (NOTIFY_SOCKET, set by systemd and by Podman's Quadlet with Notify=true;
// spec 009 plan D3). Without it there is nothing to do. A few lines over a datagram socket, as
// sd_notify(3) describes; no library.
func notifySystemd(getenv func(string) string, state string) error {
	path := getenv("NOTIFY_SOCKET")
	if path == "" {
		return nil
	}
	if strings.HasPrefix(path, "@") { // an abstract socket (Linux)
		path = "\x00" + path[1:]
	}
	conn, err := net.DialUnix("unixgram", nil, &net.UnixAddr{Name: path, Net: "unixgram"})
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close() }()
	_, err = conn.Write([]byte(state))
	return err
}

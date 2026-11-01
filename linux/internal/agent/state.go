package agent

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/tonimelisma/latchkey/relay/agentproto"
)

// state is the server's report: how long it has been up and its time zone, with the Mac-only
// fields at their fixed neutral values (agent-protocol.md, State object).
func state() agentproto.State {
	s := agentproto.State{
		PowerSource: agentproto.PowerUnknown, ThermalState: "nominal", KeepAwake: agentproto.KeepAwakeOn,
		ObservedAt: time.Now().UTC().Truncate(time.Second),
	}
	if up, ok := uptime(); ok {
		s.UptimeS = &up
	}
	if tz := timeZone(); tz != "" {
		s.TimeZone = &tz
	}
	return s
}

func uptime() (int64, bool) {
	data, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0, false
	}
	first, _, _ := strings.Cut(strings.TrimSpace(string(data)), " ")
	f, err := strconv.ParseFloat(first, 64)
	if err != nil {
		return 0, false
	}
	return int64(f), true
}

// timeZone is the IANA name: TZ, /etc/timezone, or where /etc/localtime points.
func timeZone() string {
	if tz := strings.TrimPrefix(os.Getenv("TZ"), ":"); tz != "" && !strings.HasPrefix(tz, "/") {
		return tz
	}
	if data, err := os.ReadFile("/etc/timezone"); err == nil {
		if tz := strings.TrimSpace(string(data)); tz != "" {
			return tz
		}
	}
	if target, err := filepath.EvalSymlinks("/etc/localtime"); err == nil {
		if _, tz, ok := strings.Cut(target, "zoneinfo/"); ok {
			return tz
		}
	}
	return ""
}

// osVersion is the distribution's own name for itself, as in /etc/os-release.
func osVersion() string {
	f, err := os.Open("/etc/os-release")
	if err != nil {
		return "Linux"
	}
	defer func() { _ = f.Close() }()
	s := bufio.NewScanner(f)
	for s.Scan() {
		if v, ok := strings.CutPrefix(s.Text(), "PRETTY_NAME="); ok {
			return strings.Trim(v, `"'`)
		}
	}
	return "Linux"
}

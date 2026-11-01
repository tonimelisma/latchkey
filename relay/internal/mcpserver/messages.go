package mcpserver

import (
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/tonimelisma/latchkey/relay/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// appendStatusLine adds the state line as the result's last block (FR-065), starting on its own
// line (FR-200): Claude's apps join a result's text blocks with nothing between them, so a
// result not ending in a line break ran straight into it ("live checkMac: online", live check
// 2026-10-25). The line break goes in the added block; the machine's own blocks are never changed.
func appendStatusLine(res *mcp.CallToolResult, line string) {
	if needsLineBreak(res.Content) {
		line = "\n" + line
	}
	res.Content = append(res.Content, &mcp.TextContent{Text: line})
}

// needsLineBreak reports whether text added after these blocks would not start on its own line:
// the last block that shows something is not text, or is text not ending in a line break.
// Empty text blocks show nothing and are skipped; after nothing at all no break is needed.
func needsLineBreak(content []mcp.Content) bool {
	for i := len(content) - 1; i >= 0; i-- {
		text, ok := content[i].(*mcp.TextContent)
		if !ok {
			return true
		}
		if text.Text != "" {
			return !strings.HasSuffix(text.Text, "\n")
		}
	}
	return false
}

// Texts for calls that cannot complete (contracts/mcp-surface.md). Claude relays them to the user.
const (
	neverPairedText = "No machine is connected to this account yet. Open the Latchkey app on your Mac and click Connect, or install Latchkey on a Linux server."
)

func revokedText(name string) string {
	return name + " was disconnected from this account while the request was running."
}

func disconnectedText(name string) string {
	return name + " lost its connection while the request was running."
}

func unreadableText(name string) string {
	return name + " sent a result the relay couldn't read."
}

func timeoutText(name string, d time.Duration) string {
	s := strconv.FormatFloat(d.Seconds(), 'f', -1, 64)
	unit := "seconds"
	if d == time.Second {
		unit = "second"
	}
	return fmt.Sprintf("%s didn't answer within %s %s. It may be busy or losing its connection.", name, s, unit)
}

// kindWord is how a machine's kind reads in a sentence.
func kindWord(kind string) string {
	if kind == store.KindLinux {
		return "Linux"
	}
	return "Mac"
}

// offlineText explains why a machine can't run a tool right now (FR-010, spec 010 FR-1008).
func offlineText(m machine, now time.Time) string {
	head := m.Device.Name + " is offline."
	if m.LastSeen.IsZero() {
		return head + " It hasn't connected to Latchkey yet."
	}
	var tz *string
	if m.State != nil {
		tz = m.State.TimeZone
	}
	at := when(m.LastSeen, tz, now)
	if m.Device.Kind == store.KindLinux {
		switch m.OfflineReason {
		case agentproto.ReasonSystemShutdown:
			return fmt.Sprintf("%s It shut down %s.", head, at)
		case agentproto.ReasonUserQuit:
			return fmt.Sprintf("%s Latchkey was stopped on it %s.", head, at)
		}
		return fmt.Sprintf("%s It was last seen %s.", head, at)
	}
	switch {
	case m.OfflineReason == agentproto.ReasonLowBattery && m.State != nil:
		return fmt.Sprintf("%s It went to sleep for low battery at %d%%, %s.", head, m.State.BatteryPercent, at)
	case m.OfflineReason == agentproto.ReasonTooHot:
		return fmt.Sprintf("%s It went to sleep because it was too hot, %s.", head, at)
	case m.OfflineReason == agentproto.ReasonSystemSleep:
		return fmt.Sprintf("%s It went to sleep %s.", head, at)
	case m.OfflineReason == agentproto.ReasonSystemShutdown:
		return fmt.Sprintf("%s It shut down %s.", head, at)
	case m.OfflineReason == agentproto.ReasonUserQuit:
		return fmt.Sprintf("%s The Latchkey app was quit %s.", head, at)
	}
	if m.State == nil {
		return fmt.Sprintf("%s It was last seen %s.", head, at)
	}
	text := fmt.Sprintf("%s It was last seen %s with %d%% battery", head, at, m.State.BatteryPercent)
	if p := powerPhrase(m.State); p != "" {
		text += ", " + p
	}
	return text + "."
}

func powerPhrase(s *agentproto.State) string {
	switch {
	case s.Charging:
		return "charging"
	case s.PowerSource == agentproto.PowerBattery:
		return "on battery power"
	case s.PowerSource == agentproto.PowerAC:
		return "plugged in"
	case s.PowerSource == agentproto.PowerUPS:
		return "on UPS power"
	}
	return ""
}

// statusLine is the answering machine's state, appended to every machine tool result so Claude
// knows its condition as a byproduct of real work (spec 001 FR-065, spec 010 FR-1009).
func statusLine(name, kind string, s *agentproto.State) string {
	head := fmt.Sprintf("%s (%s): online", name, kindWord(kind))
	if s == nil {
		return head
	}
	if kind == store.KindLinux {
		if s.UptimeS != nil {
			return head + " · up " + uptime(time.Duration(*s.UptimeS)*time.Second)
		}
		return head
	}
	line := fmt.Sprintf("%s · %d%% battery", head, s.BatteryPercent)
	if p := powerPhrase(s); p != "" {
		line += ", " + p
	}
	line += " · " + keepAwakePhrase(s.KeepAwake)
	if s.PowerSource == agentproto.PowerBattery && !s.Charging && s.BatteryPercent <= lowBatteryWarning {
		line += " · battery low: the Mac goes to sleep at 15%"
	}
	if s.ThermalState == "serious" || s.ThermalState == "critical" {
		line += " · the Mac is too hot and may go to sleep"
	}
	return line
}

// othersLine names the account's other machines, so any answer tells Claude what else it can
// reach (Toni, 2026-10-31); "" when there are none.
func othersLine(ms []machine, except string, now time.Time) string {
	var parts []string
	for _, m := range ms {
		if m.Device.ID != except {
			parts = append(parts, fmt.Sprintf("%s (%s, %s)", m.Device.Name, kindWord(m.Device.Kind), onlineWord(m, now)))
		}
	}
	if len(parts) == 0 {
		return ""
	}
	return "Other machines: " + strings.Join(parts, ", ")
}

// onlineWord is "online", or how long ago an offline machine was last seen.
func onlineWord(m machine, now time.Time) string {
	switch {
	case m.Online:
		return "online"
	case m.LastSeen.IsZero():
		return "offline, never connected"
	}
	return "offline, last seen " + ago(now.Sub(m.LastSeen))
}

// uptime reads "12 days", "5 hours", or "20 minutes".
func uptime(d time.Duration) string {
	switch {
	case d >= 48*time.Hour:
		return plural(int(d/(24*time.Hour)), "day")
	case d >= 2*time.Hour:
		return plural(int(d/time.Hour), "hour")
	}
	return plural(int(d/time.Minute), "minute")
}

// lowBatteryWarning is 10 points above the Mac's 15% sleep threshold (spec 001 FR-032).
const lowBatteryWarning = 25

func keepAwakePhrase(k string) string {
	switch k {
	case agentproto.KeepAwakeOn:
		return "keep-awake on"
	case agentproto.KeepAwakeOffLowBattery:
		return "keep-awake off (battery low)"
	case agentproto.KeepAwakeOffTooHot:
		return "keep-awake off (too hot)"
	case agentproto.KeepAwakeOffHelperUnusable:
		return "keep-awake off (not approved in System Settings)"
	}
	return "keep-awake off"
}

// when renders a past time in the machine's time zone, with a relative time: "at 2:02 PM (3
// hours ago)", "at 3:02 PM on Oct 17 (2 days ago)". Unknown time zones fall back to labeled UTC
// (FR-037).
func when(t time.Time, tz *string, now time.Time) string {
	loc, label := time.UTC, " UTC"
	if tz != nil && *tz != "" {
		if l, err := time.LoadLocation(*tz); err == nil {
			loc, label = l, ""
		}
	}
	local, localNow := t.In(loc), now.In(loc)
	out := "at " + local.Format("3:04 PM") + label
	switch {
	case local.Year() != localNow.Year():
		out += " on " + local.Format("Jan 2, 2006")
	case local.YearDay() != localNow.YearDay():
		out += " on " + local.Format("Jan 2")
	}
	return out + " (" + ago(now.Sub(t)) + ")"
}

func ago(d time.Duration) string {
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return plural(int(d/time.Minute), "minute") + " ago"
	case d < 24*time.Hour:
		return plural(int(d/time.Hour), "hour") + " ago"
	}
	return plural(int(math.Floor(d.Hours()/24)), "day") + " ago"
}

func plural(n int, unit string) string {
	if n == 1 {
		return "1 " + unit
	}
	return strconv.Itoa(n) + " " + unit + "s"
}

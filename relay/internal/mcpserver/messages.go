package mcpserver

import (
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/tonimelisma/latchkey/relay/agentproto"
)

// appendStatusLine adds the state line as the result's last block (FR-065), starting on its own
// line (FR-200): Claude's apps join a result's text blocks with nothing between them, so a
// result not ending in a line break ran straight into it ("live checkMac: online", live check
// 2026-10-25). The line break goes in the added block; the Mac's own blocks are never changed.
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

// status is what the relay knows about a user's Mac (FR-020).
type status struct {
	Paired        bool
	Online        bool
	LastSeen      time.Time
	OfflineReason string
	State         *agentproto.State // last reported; nil if never reported
}

// Texts for calls that cannot complete (contracts/mcp-surface.md). Claude relays them to the user.
const (
	neverPairedText  = "No Mac is connected to this account yet. Open the Latchkey app on your Mac and click Connect."
	revokedText      = "Your Mac was disconnected from this account while the request was running."
	disconnectedText = "Your Mac lost its connection while the request was running."
)

func timeoutText(d time.Duration) string {
	s := strconv.FormatFloat(d.Seconds(), 'f', -1, 64)
	unit := "seconds"
	if d == time.Second {
		unit = "second"
	}
	return fmt.Sprintf("Your Mac didn't answer within %s %s. It may be busy or losing its connection.", s, unit)
}

// offlineText explains why a Mac tool cannot run right now (FR-010).
func offlineText(s status, now time.Time) string {
	if !s.Paired {
		return neverPairedText
	}
	if s.LastSeen.IsZero() {
		return "Your Mac is offline. It hasn't connected to Latchkey yet."
	}
	var tz *string
	if s.State != nil {
		tz = s.State.TimeZone
	}
	at := when(s.LastSeen, tz, now)
	switch {
	case s.OfflineReason == agentproto.ReasonLowBattery && s.State != nil:
		return fmt.Sprintf("Your Mac is offline. It went to sleep for low battery at %d%%, %s.", s.State.BatteryPercent, at)
	case s.OfflineReason == agentproto.ReasonTooHot:
		return fmt.Sprintf("Your Mac is offline. It went to sleep because it was too hot, %s.", at)
	case s.OfflineReason == agentproto.ReasonSystemSleep:
		return fmt.Sprintf("Your Mac is offline. It went to sleep %s.", at)
	case s.OfflineReason == agentproto.ReasonSystemShutdown:
		return fmt.Sprintf("Your Mac is offline. It shut down %s.", at)
	case s.OfflineReason == agentproto.ReasonUserQuit:
		return fmt.Sprintf("Your Mac is offline. The Latchkey app was quit %s.", at)
	}
	if s.State == nil {
		return fmt.Sprintf("Your Mac is offline. It was last seen %s.", at)
	}
	text := fmt.Sprintf("Your Mac is offline. It was last seen %s with %d%% battery", at, s.State.BatteryPercent)
	if p := powerPhrase(s.State); p != "" {
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

// statusLine is the Mac's state, appended to every Mac tool result so Claude knows the laptop's
// condition as a byproduct of real work (spec 001 FR-065).
func statusLine(s *agentproto.State) string {
	if s == nil {
		return "Mac: online"
	}
	line := fmt.Sprintf("Mac: online · %d%% battery", s.BatteryPercent)
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

// when renders a past time in the Mac's time zone, with a relative time: "at 2:02 PM (3 hours
// ago)", "at 3:02 PM on Oct 17 (2 days ago)". Unknown time zones fall back to labeled UTC (FR-037).
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

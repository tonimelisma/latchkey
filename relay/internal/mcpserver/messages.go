package mcpserver

import (
	"fmt"
	"math"
	"strconv"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
)

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

// onlineText summarizes a connected Mac for laptop_status.
func onlineText(s *agentproto.State) string {
	text := fmt.Sprintf("Your Mac is online: %d%% battery", s.BatteryPercent)
	if p := powerPhrase(s); p != "" {
		text += ", " + p
	}
	return text + ". " + keepAwakeText(s.KeepAwake)
}

func keepAwakeText(k string) string {
	switch k {
	case agentproto.KeepAwakeOn:
		return "Keep-awake is on."
	case agentproto.KeepAwakeOffUser:
		return "Keep-awake is off (turned off on the Mac)."
	case agentproto.KeepAwakeOffLowBattery:
		return "Keep-awake is off because the battery is low."
	case agentproto.KeepAwakeOffTooHot:
		return "Keep-awake is off because the Mac is too hot."
	case agentproto.KeepAwakeOffHelperUnusable:
		return "Keep-awake is off because it hasn't been approved in System Settings."
	}
	return "Keep-awake state is unknown."
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

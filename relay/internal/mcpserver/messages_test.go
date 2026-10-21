package mcpserver

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"

	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
)

func ptr[T any](v T) *T { return &v }

// now is 5:02 PM in Los Angeles on 2026-10-19.
var now = time.Date(2026, 10, 20, 0, 2, 0, 0, time.UTC)

func lastState(percent int, power string) *agentproto.State {
	return &agentproto.State{
		BatteryPercent: percent, PowerSource: power, ThermalState: "nominal",
		TimeZone: ptr("America/Los_Angeles"), KeepAwake: agentproto.KeepAwakeOn,
	}
}

func TestOfflineText(t *testing.T) {
	threeHoursAgo := now.Add(-3 * time.Hour)
	tests := []struct {
		name string
		s    status
		want string
	}{
		{
			"never paired",
			status{},
			"No Mac is connected to this account yet. Open the Latchkey app on your Mac and click Connect.",
		},
		{
			"paired, never connected",
			status{Paired: true},
			"Your Mac is offline. It hasn't connected to Latchkey yet.",
		},
		{
			"low battery",
			status{Paired: true, LastSeen: threeHoursAgo, OfflineReason: agentproto.ReasonLowBattery, State: lastState(14, "battery")},
			"Your Mac is offline. It went to sleep for low battery at 14%, at 2:02 PM (3 hours ago).",
		},
		{
			"too hot",
			status{Paired: true, LastSeen: threeHoursAgo, OfflineReason: agentproto.ReasonTooHot, State: lastState(60, "ac")},
			"Your Mac is offline. It went to sleep because it was too hot, at 2:02 PM (3 hours ago).",
		},
		{
			"system sleep",
			status{Paired: true, LastSeen: threeHoursAgo, OfflineReason: agentproto.ReasonSystemSleep, State: lastState(60, "ac")},
			"Your Mac is offline. It went to sleep at 2:02 PM (3 hours ago).",
		},
		{
			"shutdown",
			status{Paired: true, LastSeen: threeHoursAgo, OfflineReason: agentproto.ReasonSystemShutdown, State: lastState(60, "ac")},
			"Your Mac is offline. It shut down at 2:02 PM (3 hours ago).",
		},
		{
			"app quit",
			status{Paired: true, LastSeen: threeHoursAgo, OfflineReason: agentproto.ReasonUserQuit, State: lastState(60, "ac")},
			"Your Mac is offline. The Latchkey app was quit at 2:02 PM (3 hours ago).",
		},
		{
			"reason unknown, battery",
			status{Paired: true, LastSeen: threeHoursAgo, State: lastState(62, "battery")},
			"Your Mac is offline. It was last seen at 2:02 PM (3 hours ago) with 62% battery, on battery power.",
		},
		{
			"reason unknown, plugged in",
			status{Paired: true, LastSeen: threeHoursAgo, State: lastState(100, "ac")},
			"Your Mac is offline. It was last seen at 2:02 PM (3 hours ago) with 100% battery, plugged in.",
		},
		{
			"reason unknown, power unknown",
			status{Paired: true, LastSeen: threeHoursAgo, State: lastState(50, "unknown")},
			"Your Mac is offline. It was last seen at 2:02 PM (3 hours ago) with 50% battery.",
		},
		{
			"unrecognized reason",
			status{Paired: true, LastSeen: threeHoursAgo, OfflineReason: "future_reason", State: lastState(62, "ups")},
			"Your Mac is offline. It was last seen at 2:02 PM (3 hours ago) with 62% battery, on UPS power.",
		},
		{
			"no state",
			status{Paired: true, LastSeen: threeHoursAgo},
			"Your Mac is offline. It was last seen at 9:02 PM UTC on Oct 19 (3 hours ago).",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			assert.Equal(t, tt.want, offlineText(tt.s, now))
		})
	}
}

func TestWhen(t *testing.T) {
	la := ptr("America/Los_Angeles")
	tests := []struct {
		name string
		at   time.Time
		tz   *string
		want string
	}{
		{"just now", now.Add(-20 * time.Second), la, "at 5:01 PM (just now)"},
		{"one minute", now.Add(-time.Minute), la, "at 5:01 PM (1 minute ago)"},
		{"minutes", now.Add(-42 * time.Minute), la, "at 4:20 PM (42 minutes ago)"},
		{"one hour", now.Add(-time.Hour), la, "at 4:02 PM (1 hour ago)"},
		{"yesterday", now.Add(-20 * time.Hour), la, "at 9:02 PM on Oct 18 (20 hours ago)"},
		{"days", now.Add(-50 * time.Hour), la, "at 3:02 PM on Oct 17 (2 days ago)"},
		{"one day", now.Add(-25 * time.Hour), la, "at 4:02 PM on Oct 18 (1 day ago)"},
		{"last year", time.Date(2025, 12, 31, 20, 0, 0, 0, time.UTC), la, "at 12:00 PM on Dec 31, 2025 (292 days ago)"},
		{"no time zone", now.Add(-3 * time.Hour), nil, "at 9:02 PM UTC on Oct 19 (3 hours ago)"},
		{"bad time zone", now.Add(-3 * time.Hour), ptr("Mars/Olympus"), "at 9:02 PM UTC on Oct 19 (3 hours ago)"},
		{"clock skew", now.Add(time.Minute), la, "at 5:03 PM (just now)"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			assert.Equal(t, tt.want, when(tt.at, tt.tz, now))
		})
	}
}

func TestCallFailureTexts(t *testing.T) {
	assert.Equal(t, "Your Mac didn't answer within 5 seconds. It may be busy or losing its connection.", timeoutText(5*time.Second))
	assert.Equal(t, "Your Mac didn't answer within 1 second. It may be busy or losing its connection.", timeoutText(time.Second))
	assert.Equal(t, "Your Mac didn't answer within 1.5 seconds. It may be busy or losing its connection.", timeoutText(1500*time.Millisecond))
	assert.Equal(t, "Your Mac was disconnected from this account while the request was running.", revokedText)
	assert.Equal(t, "Your Mac lost its connection while the request was running.", disconnectedText)
}

func TestOnlineText(t *testing.T) {
	s := lastState(82, "battery")
	assert.Equal(t, "Your Mac is online: 82% battery, on battery power. Keep-awake is on.",
		onlineText(s))
	s.KeepAwake = agentproto.KeepAwakeOffLowBattery
	assert.Equal(t, "Your Mac is online: 82% battery, on battery power. Keep-awake is off because the battery is low.",
		onlineText(s))
	s.KeepAwake = agentproto.KeepAwakeOffHelperUnusable
	s.PowerSource = "ac"
	s.Charging = true
	assert.Equal(t, "Your Mac is online: 82% battery, charging. Keep-awake is off because it hasn't been approved in System Settings.",
		onlineText(s))
}

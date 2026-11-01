package mcpserver

import (
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// now is 5:02 PM in Los Angeles on 2026-10-19.
var now = time.Date(2026, 10, 20, 0, 2, 0, 0, time.UTC)

func lastState(percent int, power string) *agentproto.State {
	return &agentproto.State{
		BatteryPercent: percent, PowerSource: power, ThermalState: "nominal",
		TimeZone: ptr("America/Los_Angeles"), KeepAwake: agentproto.KeepAwakeOn,
	}
}

func mac(name string) store.Device {
	return store.Device{ID: "dev_" + name, Name: name, Kind: store.KindMac}
}

func linux(name string) store.Device {
	return store.Device{ID: "dev_" + name, Name: name, Kind: store.KindLinux}
}

func TestOfflineText(t *testing.T) {
	threeHoursAgo := now.Add(-3 * time.Hour)
	m := mac("Toni's MacBook Pro")
	tests := []struct {
		name string
		m    machine
		want string
	}{
		{
			"paired, never connected",
			machine{Device: m},
			"Toni's MacBook Pro is offline. It hasn't connected to Latchkey yet.",
		},
		{
			"low battery",
			machine{Device: m, LastSeen: threeHoursAgo, OfflineReason: agentproto.ReasonLowBattery, State: lastState(14, "battery")},
			"Toni's MacBook Pro is offline. It went to sleep for low battery at 14%, at 2:02 PM (3 hours ago).",
		},
		{
			"too hot",
			machine{Device: m, LastSeen: threeHoursAgo, OfflineReason: agentproto.ReasonTooHot, State: lastState(60, "ac")},
			"Toni's MacBook Pro is offline. It went to sleep because it was too hot, at 2:02 PM (3 hours ago).",
		},
		{
			"system sleep",
			machine{Device: m, LastSeen: threeHoursAgo, OfflineReason: agentproto.ReasonSystemSleep, State: lastState(60, "ac")},
			"Toni's MacBook Pro is offline. It went to sleep at 2:02 PM (3 hours ago).",
		},
		{
			"shutdown",
			machine{Device: m, LastSeen: threeHoursAgo, OfflineReason: agentproto.ReasonSystemShutdown, State: lastState(60, "ac")},
			"Toni's MacBook Pro is offline. It shut down at 2:02 PM (3 hours ago).",
		},
		{
			"app quit",
			machine{Device: m, LastSeen: threeHoursAgo, OfflineReason: agentproto.ReasonUserQuit, State: lastState(60, "ac")},
			"Toni's MacBook Pro is offline. The Latchkey app was quit at 2:02 PM (3 hours ago).",
		},
		{
			"reason unknown, battery",
			machine{Device: m, LastSeen: threeHoursAgo, State: lastState(62, "battery")},
			"Toni's MacBook Pro is offline. It was last seen at 2:02 PM (3 hours ago) with 62% battery, on battery power.",
		},
		{
			"reason unknown, plugged in",
			machine{Device: m, LastSeen: threeHoursAgo, State: lastState(100, "ac")},
			"Toni's MacBook Pro is offline. It was last seen at 2:02 PM (3 hours ago) with 100% battery, plugged in.",
		},
		{
			"reason unknown, power unknown",
			machine{Device: m, LastSeen: threeHoursAgo, State: lastState(50, "unknown")},
			"Toni's MacBook Pro is offline. It was last seen at 2:02 PM (3 hours ago) with 50% battery.",
		},
		{
			"unrecognized reason",
			machine{Device: m, LastSeen: threeHoursAgo, OfflineReason: "future_reason", State: lastState(62, "ups")},
			"Toni's MacBook Pro is offline. It was last seen at 2:02 PM (3 hours ago) with 62% battery, on UPS power.",
		},
		{
			"no state",
			machine{Device: m, LastSeen: threeHoursAgo},
			"Toni's MacBook Pro is offline. It was last seen at 9:02 PM UTC on Oct 19 (3 hours ago).",
		},
		{
			"Linux server shut down",
			machine{Device: linux("homeserver"), LastSeen: threeHoursAgo, OfflineReason: agentproto.ReasonSystemShutdown, State: &agentproto.State{TimeZone: ptr("America/Los_Angeles")}},
			"homeserver is offline. It shut down at 2:02 PM (3 hours ago).",
		},
		{
			"Linux service stopped",
			machine{Device: linux("homeserver"), LastSeen: threeHoursAgo, OfflineReason: agentproto.ReasonUserQuit},
			"homeserver is offline. Latchkey was stopped on it at 9:02 PM UTC on Oct 19 (3 hours ago).",
		},
		{
			"Linux server gone silent: no battery talk",
			machine{Device: linux("homeserver"), LastSeen: threeHoursAgo, State: lastState(0, "unknown")},
			"homeserver is offline. It was last seen at 2:02 PM (3 hours ago).",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			assert.Equal(t, tt.want, offlineText(tt.m, now))
		})
	}
	assert.Equal(t, "No machine is connected to this account yet. Open the Latchkey app on your Mac and click Connect, or install Latchkey on a Linux server.", neverPairedText)
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
	assert.Equal(t, "homeserver didn't answer within 5 seconds. It may be busy or losing its connection.", timeoutText("homeserver", 5*time.Second))
	assert.Equal(t, "Old Mac didn't answer within 1 second. It may be busy or losing its connection.", timeoutText("Old Mac", time.Second))
	assert.Equal(t, "Old Mac didn't answer within 1.5 seconds. It may be busy or losing its connection.", timeoutText("Old Mac", 1500*time.Millisecond))
	assert.Equal(t, "Old Mac was disconnected from this account while the request was running.", revokedText("Old Mac"))
	assert.Equal(t, "Old Mac lost its connection while the request was running.", disconnectedText("Old Mac"))
	assert.Equal(t, "Old Mac sent a result the relay couldn't read.", unreadableText("Old Mac"))
}

func TestStatusLine(t *testing.T) {
	const n = "Toni's MacBook Pro"
	s := lastState(64, "battery")
	assert.Equal(t, n+" (Mac): online · 64% battery, on battery power · keep-awake on", statusLine(n, store.KindMac, s))

	s = lastState(82, "ac")
	s.Charging = true
	assert.Equal(t, n+" (Mac): online · 82% battery, charging · keep-awake on", statusLine(n, store.KindMac, s))

	s = lastState(22, "battery")
	assert.Equal(t, n+" (Mac): online · 22% battery, on battery power · keep-awake on · battery low: the Mac goes to sleep at 15%", statusLine(n, store.KindMac, s))

	s = lastState(70, "ac")
	s.ThermalState = "serious"
	s.KeepAwake = agentproto.KeepAwakeOffTooHot
	assert.Equal(t, n+" (Mac): online · 70% battery, plugged in · keep-awake off (too hot) · the Mac is too hot and may go to sleep", statusLine(n, store.KindMac, s))

	s = lastState(90, "ac")
	s.KeepAwake = agentproto.KeepAwakeOffHelperUnusable
	assert.Equal(t, n+" (Mac): online · 90% battery, plugged in · keep-awake off (not approved in System Settings)", statusLine(n, store.KindMac, s))

	assert.Equal(t, n+" (Mac): online", statusLine(n, store.KindMac, nil))

	// A Linux server: its uptime, never battery or keep-awake (spec 010 plan D5).
	up := int64(12*24*3600 + 3600)
	assert.Equal(t, "homeserver (Linux): online · up 12 days", statusLine("homeserver", store.KindLinux, &agentproto.State{UptimeS: &up}))
	up = 5 * 3600
	assert.Equal(t, "homeserver (Linux): online · up 5 hours", statusLine("homeserver", store.KindLinux, &agentproto.State{UptimeS: &up}))
	up = 20 * 60
	assert.Equal(t, "homeserver (Linux): online · up 20 minutes", statusLine("homeserver", store.KindLinux, &agentproto.State{UptimeS: &up}))
	assert.Equal(t, "homeserver (Linux): online", statusLine("homeserver", store.KindLinux, &agentproto.State{}))
}

func TestOthersLine(t *testing.T) {
	ms := []machine{
		{Device: mac("Toni's MacBook Pro"), Online: true},
		{Device: linux("homeserver"), LastSeen: now.Add(-3 * time.Hour)},
		{Device: mac("Old Mac")},
	}
	assert.Equal(t, "Other machines: homeserver (Linux, offline, last seen 3 hours ago), Old Mac (Mac, offline, never connected)",
		othersLine(ms, "dev_Toni's MacBook Pro", now))
	assert.Empty(t, othersLine(ms[:1], "dev_Toni's MacBook Pro", now), "one machine: no line")
}

// FR-200: whatever a result ends with, the state line starts on its own line, the result's own
// blocks are untouched, and no blank line is added where the text already ends with a line break.
func TestStatusLineStartsOnItsOwnLine(t *testing.T) {
	const line = "Mac: online"
	text := func(s string) mcp.Content { return &mcp.TextContent{Text: s} }
	image := &mcp.ImageContent{MIMEType: "image/png", Data: []byte{1}}
	for name, tc := range map[string]struct {
		content []mcp.Content
		isError bool
		want    string // everything Claude reads: the text blocks joined with nothing between them
	}{
		"text without a line break":       {content: []mcp.Content{text("live check")}, want: "live check\nMac: online"},
		"text ending with a line break":   {content: []mcp.Content{text("done\n")}, want: "done\nMac: online"},
		"text ending with a blank line":   {content: []mcp.Content{text("done\n\n")}, want: "done\n\nMac: online"},
		"text ending with CR LF":          {content: []mcp.Content{text("done\r\n")}, want: "done\r\nMac: online"},
		"empty text":                      {content: []mcp.Content{text("")}, want: "Mac: online"},
		"no blocks":                       {content: nil, want: "Mac: online"},
		"text then empty text":            {content: []mcp.Content{text("abc"), text("")}, want: "abc\nMac: online"},
		"line break then empty text":      {content: []mcp.Content{text("abc\n"), text("")}, want: "abc\nMac: online"},
		"several text blocks":             {content: []mcp.Content{text("a\n"), text("b")}, want: "a\nb\nMac: online"},
		"an image last":                   {content: []mcp.Content{text("shot\n"), image}, want: "shot\n\nMac: online"},
		"only an image":                   {content: []mcp.Content{image}, want: "\nMac: online"},
		"image then text":                 {content: []mcp.Content{image, text("caption")}, want: "caption\nMac: online"},
		"an error result":                 {content: []mcp.Content{text("It can be put back from there.")}, isError: true, want: "It can be put back from there.\nMac: online"},
		"an error ending with line break": {content: []mcp.Content{text("No such file.\n")}, isError: true, want: "No such file.\nMac: online"},
	} {
		t.Run(name, func(t *testing.T) {
			before := make([]string, len(tc.content))
			for i, c := range tc.content {
				if tx, ok := c.(*mcp.TextContent); ok {
					before[i] = tx.Text
				}
			}
			res := &mcp.CallToolResult{Content: tc.content, IsError: tc.isError}
			appendStatusLine(res, line)

			require.Len(t, res.Content, len(tc.content)+1, "one block added, none removed")
			joined := ""
			for i, c := range res.Content {
				tx, ok := c.(*mcp.TextContent)
				if !ok {
					assert.Same(t, tc.content[i], c, "other blocks are passed through")
					continue
				}
				if i < len(tc.content) {
					assert.Equal(t, before[i], tx.Text, "the result's own text is unchanged")
				}
				joined += tx.Text
			}
			assert.Equal(t, tc.want, joined)
			assert.Equal(t, tc.isError, res.IsError)
			last, ok := res.Content[len(res.Content)-1].(*mcp.TextContent)
			require.True(t, ok)
			assert.Equal(t, line, strings.TrimLeft(last.Text, "\n"), "the last block is the state line")
		})
	}
}

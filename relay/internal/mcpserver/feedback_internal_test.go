package mcpserver

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/tonimelisma/latchkey/relay/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/store"
	"github.com/tonimelisma/latchkey/relay/reports"
)

// A report lists the machines Claude named, or every online machine when it named none
// (spec 014 FR-1412; decided 2026-11-24); never a machine's name.
func TestReportMachines(t *testing.T) {
	locked := true
	mac := machine{
		Online: true, Device: store.Device{Name: "Sam's MacBook", Kind: store.KindMac, AppVersion: "0.8.235", OSVersion: "26.1"},
		State: &agentproto.State{ScreenLocked: &locked},
	}
	server := machine{Online: true, Device: store.Device{Name: "home-server", Kind: store.KindLinux, AppVersion: "0.1.7", OSVersion: "Ubuntu 26.10"}}
	gone := machine{Online: false, Device: store.Device{Name: "old-mac", AppVersion: "0.8.1"}}
	ms := []machine{mac, server, gone}

	macFacts := reports.Machine{Named: true, Kind: "mac", Version: "0.8.235", System: "macOS 26.1", Screen: "locked"}
	assert.Equal(t, []reports.Machine{macFacts}, reportMachines(ms, []string{"sam's macbook"}), "the named machine, any case")

	both := reportMachines(ms, []string{"home-server", "Sam's MacBook", "no-such-machine"})
	assert.Len(t, both, 2, "every named machine; an unknown name is left out")

	all := reportMachines(ms, nil)
	assert.Equal(t, []reports.Machine{
		{Kind: "mac", Version: "0.8.235", System: "macOS 26.1", Screen: "locked"},
		{Kind: "linux", Version: "0.1.7", System: "Ubuntu 26.10"},
	}, all, "none named: every online machine, not marked named")

	assert.Equal(t, all, reportMachines(ms, []string{"typo"}), "only unknown names: as if none were named")
	assert.Empty(t, reportMachines([]machine{gone}, nil), "none online, none named: nothing")
	assert.Equal(t, "Sam's MacBook", mac.Device.Name)
	for _, m := range append(both, all...) {
		assert.NotContains(t, m.Kind+m.Version+m.System+m.Screen, "MacBook", "never a machine's name")
		assert.NotContains(t, m.Kind+m.Version+m.System+m.Screen, "home-server", "never a machine's name")
	}
}

// The requirements this file's tests cite (docs/requirements/; script/process-check).
// Validates: FR-1412

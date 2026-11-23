//go:build linux

package shell

import (
	"os"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

// A folder on an ordinary file system is no control group, so commands never start "inside" one
// (2026-11-22: on a host with the older, mixed cgroup layout every command failed to start).
func TestOnlyACgroup2HierarchyCounts(t *testing.T) {
	assert.False(t, isCgroup2(t.TempDir()), "a plain folder")
	assert.False(t, isCgroup2("/nonexistent"), "a missing folder")
	mounts, err := os.ReadFile("/proc/self/mounts")
	if err != nil {
		t.Skip("no /proc/self/mounts")
	}
	for line := range strings.SplitSeq(string(mounts), "\n") {
		f := strings.Fields(line)
		if len(f) > 2 && f[2] == "cgroup2" {
			assert.True(t, isCgroup2(f[1]), "the cgroup2 mount %s", f[1])
			return
		}
	}
}

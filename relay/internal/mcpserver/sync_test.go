package mcpserver

import (
	"context"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/hub"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Two tool-list syncs at once: the one that read the older list must not apply it after the one
// that read the newer list (security review: the store was read before the lock was taken).
func TestSyncToolsNeverAppliesAnOlderList(t *testing.T) {
	st, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "relay.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = st.Close() })
	s := New(st, hub.New(st, hub.Config{}), Options{})

	tool := func(name string) *mcp.Tool {
		return &mcp.Tool{Name: name, InputSchema: map[string]any{"type": "object"}}
	}
	var (
		mu         sync.Mutex
		reads      int
		firstRead  = make(chan struct{})
		secondDone = make(chan struct{})
	)
	s.loadTools = func(context.Context, string) []*mcp.Tool {
		mu.Lock()
		reads++
		n := reads
		mu.Unlock()
		if n > 1 {
			return []*mcp.Tool{tool("new")} // the list as it is now
		}
		// The first sync read the list before it changed, and is slow to apply it.
		close(firstRead)
		select {
		case <-secondDone:
		case <-time.After(300 * time.Millisecond):
		}
		return []*mcp.Tool{tool("old")}
	}

	u := &userServer{server: mcp.NewServer(&mcp.Implementation{Name: "t", Version: "0"}, nil), tools: map[string]*mcp.Tool{}}
	var wg sync.WaitGroup
	wg.Go(func() { s.syncTools(context.Background(), "usr_1", u) })
	<-firstRead
	wg.Go(func() {
		s.syncTools(context.Background(), "usr_1", u)
		close(secondDone)
	})
	wg.Wait()

	u.mu.Lock()
	defer u.mu.Unlock()
	assert.Contains(t, u.tools, "new", "the newest list wins")
	assert.NotContains(t, u.tools, "old")
}

func TestCleanSurface(t *testing.T) {
	assert.Equal(t, "claude-ai", cleanSurface("claude-ai"))
	assert.Empty(t, cleanSurface("\x00\r\n\t"))
	assert.Equal(t, "ab", cleanSurface("a​b\xff"))
}

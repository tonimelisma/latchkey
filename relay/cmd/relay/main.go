// Command relay is the Latchkey relay: the MCP server Claude connects to and the hub the Mac app
// dials into.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

func main() {
	if err := run(context.Background()); err != nil {
		fmt.Fprintln(os.Stderr, "relay:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context) error {
	cfg, err := loadConfig(os.Getenv)
	if err != nil {
		return err
	}
	db, err := store.Open(ctx, filepath.Join(cfg.DataDir, "relay.db"))
	if err != nil {
		return err
	}
	defer func() { _ = db.Close() }()
	slog.Info("database ready", "public_url", cfg.PublicURL.String(), "data_dir", cfg.DataDir)
	// The HTTP server (agent endpoint, MCP, OAuth) is added from task T016 on.
	return nil
}

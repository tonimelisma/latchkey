package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// resetKeys is `relay reset-keys --confirm`: the operator's way out when the key file that
// encrypts the relay's stored keys is lost (FR-189). It needs only DATA_DIR, and must run while
// the relay is stopped. It returns the exit code.
func resetKeys(args []string, getenv func(string) string, out, errOut io.Writer) int {
	const what = `Deletes the relay's stored signing keys. Everyone is signed out and Claude is
disconnected: each person signs in again and connects Claude again.
Accounts, passkeys and paired Macs are kept. The key file is not touched; if there
is none, the next start makes a new one.
`
	if len(args) != 1 || args[0] != "--confirm" {
		_, _ = fmt.Fprint(errOut, "usage: relay reset-keys --confirm   (with the relay stopped)\n\n"+what)
		return 2
	}
	dir := getenv("DATA_DIR")
	if dir == "" {
		_, _ = fmt.Fprintln(errOut, "relay: DATA_DIR is required")
		return 2
	}
	db := filepath.Join(dir, "relay.db")
	if _, err := os.Stat(db); err != nil {
		_, _ = fmt.Fprintf(errOut, "relay: no database at %s\n", db)
		return 1
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	if err := store.ResetKeys(ctx, db); err != nil {
		_, _ = fmt.Fprintln(errOut, "relay:", err)
		return 1
	}
	_, _ = fmt.Fprintln(out, "The stored keys are deleted. Start the relay again; everyone signs in again and connects Claude again.")
	return 0
}

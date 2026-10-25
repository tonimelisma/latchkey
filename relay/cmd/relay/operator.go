package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/operator"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// operatorCommand runs one of the operator's commands (FR-195) against the relay's database,
// beside the running server, and returns the process's exit code: 0 done, 1 failed, 2 not a
// command. The image has no shell, so these are subcommands of the relay itself:
//
//	docker exec latchkey-relay /relay account list
func operatorCommand(args []string, getenv func(string) string, stdout, stderr io.Writer) int {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if !isCommand(args) { // a mistyped command must never start a second server, or open the database
		_, _ = fmt.Fprint(stderr, operator.Usage)
		return 2
	}
	db, err := openStore(ctx, getenv)
	if err != nil {
		_, _ = fmt.Fprintln(stderr, "relay:", err)
		return 1
	}
	defer func() { _ = db.Close() }()
	err = operator.Run(ctx, operator.Env{Store: db, Out: stdout, Actor: operatorActor(getenv)}, args)
	switch {
	case errors.Is(err, operator.ErrUsage):
		_, _ = fmt.Fprint(stderr, operator.Usage)
		return 2
	case err != nil:
		_, _ = fmt.Fprintln(stderr, "relay:", err)
		return 1
	}
	return 0
}

func isCommand(args []string) bool {
	return len(args) > 0 && (args[0] == "account" || args[0] == "block" || args[0] == "unblock")
}

// openStore opens the relay's database for a command run beside the server: the one place that
// decides where the database is and how it is opened, from the same settings the server reads.
func openStore(ctx context.Context, getenv func(string) string) (*store.Store, error) {
	dir := getenv("DATA_DIR")
	if dir == "" {
		return nil, errors.New("DATA_DIR is required (it is set in the relay's container)")
	}
	path := filepath.Join(dir, "relay.db")
	if _, err := os.Stat(path); err != nil {
		return nil, fmt.Errorf("there is no relay database at %s", path)
	}
	return store.Open(ctx, path)
}

// operatorActor is who the operator log says ran a command: LATCHKEY_OPERATOR when set (several
// people sharing a server can say who they are), otherwise the system user of the process.
func operatorActor(getenv func(string) string) string {
	if name := strings.TrimSpace(getenv("LATCHKEY_OPERATOR")); name != "" {
		return name
	}
	if u, err := user.Current(); err == nil && u.Username != "" {
		return u.Username
	}
	return "uid " + strconv.Itoa(os.Getuid())
}

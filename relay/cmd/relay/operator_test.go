package main

import (
	"bytes"
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// The operator's commands are subcommands of the relay binary itself (the image has no shell):
// one line on standard output and exit 0 when done, a reason on standard error and a non-zero
// exit otherwise (FR-195).
func TestOperatorCommand(t *testing.T) {
	dir := t.TempDir()
	ctx := context.Background()
	st, err := store.Open(ctx, filepath.Join(dir, "relay.db"))
	require.NoError(t, err)
	u, err := st.CreateUser(ctx, "owner@example.com", time.Now())
	require.NoError(t, err)
	t.Cleanup(func() { _ = st.Close() }) // the server's own connection stays open meanwhile

	getenv := func(k string) string { return map[string]string{"DATA_DIR": dir, "LATCHKEY_OPERATOR": "alex"}[k] }
	run := func(args ...string) (int, string, string) {
		var out, errOut bytes.Buffer
		code := operatorCommand(args, getenv, &out, &errOut)
		return code, out.String(), errOut.String()
	}

	code, out, errOut := run("account", "suspend", "Owner@Example.com", "abuse")
	assert.Equal(t, 0, code, errOut)
	assert.Contains(t, out, "Suspended owner@example.com")
	assert.Empty(t, errOut)
	got, err := st.User(ctx, u.ID)
	require.NoError(t, err)
	assert.False(t, got.SuspendedAt.IsZero(), "the running relay's own connection sees it")
	log, err := st.OperatorLogAfter(ctx, 0)
	require.NoError(t, err)
	require.Len(t, log, 1)
	assert.Equal(t, "alex", log[0].Actor, "who ran it")

	code, out, errOut = run("account", "suspend", "nobody@example.com")
	assert.Equal(t, 1, code)
	assert.Empty(t, out)
	assert.Contains(t, errOut, "no account")

	code, out, errOut = run("acount", "list")
	assert.Equal(t, 2, code, "a mistyped command is refused; it must never start a second server")
	assert.Empty(t, out)
	assert.Contains(t, errOut, "account suspend <email> [reason]")

	code, _, errOut = run("help")
	assert.Equal(t, 2, code)
	assert.Contains(t, errOut, "block list")

	code, _, errOut = operatorCommandWithEnv(t, []string{"account", "list"}, map[string]string{})
	assert.Equal(t, 1, code)
	assert.Contains(t, errOut, "DATA_DIR")
}

func operatorCommandWithEnv(t *testing.T, args []string, env map[string]string) (int, string, string) {
	t.Helper()
	var out, errOut bytes.Buffer
	code := operatorCommand(args, func(k string) string { return env[k] }, &out, &errOut)
	return code, out.String(), errOut.String()
}

func TestOperatorActor(t *testing.T) {
	assert.Equal(t, "alex", operatorActor(func(k string) string { return map[string]string{"LATCHKEY_OPERATOR": " alex "}[k] }))
	assert.NotEmpty(t, operatorActor(func(string) string { return "" }), "otherwise the system user running the command")
}

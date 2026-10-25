// Package operator is the commands for the person running a relay (plan D14, FR-195): list
// accounts, suspend and delete them, block addresses. They are subcommands of the relay binary
// (the image has no shell) and work on the same database as the running relay, which follows
// them (server.operatorWatch).
package operator

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/account"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Usage lists the commands.
const Usage = `Commands for the person running this relay:

  relay account list                      every account: address, dates, status (no secrets)
  relay account suspend <email> [reason]  sign the account out everywhere, remove Claude's access,
                                          refuse its Mac and its sign-ins; deletes nothing
  relay account unsuspend <email>         lift a suspension
  relay account delete <email>            delete the account and everything stored about it
  relay block <email> [reason]            refuse sign-up and sign-in for an address, and suspend
                                          its account if it has one
  relay unblock <email>                   remove a block (a suspended account stays suspended)
  relay block list                        the blocked addresses

With no command, relay starts the server.
`

// ErrUsage means the arguments aren't a command; the caller prints Usage.
var ErrUsage = errors.New("not a command")

// Env is what a command works with.
type Env struct {
	Store *store.Store
	Out   io.Writer        // one plain line per command that changed or found something
	Actor string           // who runs it, for the operator log
	Now   func() time.Time // default time.Now
}

// Run executes one command. An error means nothing was done (or the command wasn't one,
// ErrUsage); the process should exit non-zero.
func Run(ctx context.Context, env Env, args []string) error {
	if env.Now == nil {
		env.Now = time.Now
	}
	if len(args) == 0 {
		return ErrUsage
	}
	rest := args[1:]
	switch args[0] {
	case "account":
		if len(rest) == 0 {
			return ErrUsage
		}
		switch rest[0] {
		case "list":
			if len(rest) != 1 {
				return ErrUsage
			}
			return env.accounts(ctx)
		case "suspend":
			return env.withEmail(rest[1:], true, func(email, reason string) error { return env.suspend(ctx, email, reason) })
		case "unsuspend":
			return env.withEmail(rest[1:], false, func(email, _ string) error { return env.unsuspend(ctx, email) })
		case "delete":
			return env.withEmail(rest[1:], false, func(email, _ string) error { return env.delete(ctx, email) })
		}
		return ErrUsage
	case "block":
		if len(rest) == 1 && rest[0] == "list" {
			return env.blocked(ctx)
		}
		return env.withEmail(rest, true, func(email, reason string) error { return env.block(ctx, email, reason) })
	case "unblock":
		return env.withEmail(rest, false, func(email, _ string) error { return env.unblock(ctx, email) })
	}
	return ErrUsage
}

// withEmail reads "<email> [reason words…]", normalizing the address as sign-up does.
func (e Env) withEmail(args []string, reasonAllowed bool, do func(email, reason string) error) error {
	if len(args) == 0 || (!reasonAllowed && len(args) > 1) {
		return ErrUsage
	}
	email := account.NormalizeEmail(args[0])
	if !account.ValidEmail(email) {
		return fmt.Errorf("%q is not an email address", args[0])
	}
	return do(email, strings.TrimSpace(strings.Join(args[1:], " ")))
}

func (e Env) say(format string, args ...any) error {
	_, err := fmt.Fprintf(e.Out, format+"\n", args...)
	return err
}

func noAccount(email string, err error) error {
	if errors.Is(err, store.ErrNotFound) {
		return fmt.Errorf("there is no account with the address %s", email)
	}
	return err
}

func (e Env) suspend(ctx context.Context, email, reason string) error {
	_, changed, err := e.Store.SuspendUser(ctx, email, reason, e.Actor, e.Now())
	if err != nil {
		return noAccount(email, err)
	}
	if !changed {
		return e.say("%s is already suspended; nothing changed.", email)
	}
	return e.say("Suspended %s: it is signed out everywhere, Claude's access is removed, and its Mac and its sign-ins are refused until you run: relay account unsuspend %s", email, email)
}

func (e Env) unsuspend(ctx context.Context, email string) error {
	_, changed, err := e.Store.UnsuspendUser(ctx, email, e.Actor, e.Now())
	if err != nil {
		return noAccount(email, err)
	}
	if !changed {
		return e.say("%s is not suspended; nothing changed.", email)
	}
	return e.say("Lifted the suspension of %s: its owner can sign in again and must approve Claude again.", email)
}

func (e Env) delete(ctx context.Context, email string) error {
	if _, err := e.Store.DeleteUserByOperator(ctx, email, e.Actor, e.Now()); err != nil {
		return noAccount(email, err)
	}
	return e.say("Deleted %s and everything this relay stored about it; its Mac is disconnected.", email)
}

func (e Env) block(ctx context.Context, email, reason string) error {
	changed, suspended, err := e.Store.BlockEmail(ctx, email, reason, e.Actor, e.Now())
	if err != nil {
		return err
	}
	switch {
	case !changed:
		return e.say("%s is already blocked; nothing changed.", email)
	case suspended:
		return e.say("Blocked %s: it can't sign up or sign in, and its account is suspended.", email)
	}
	return e.say("Blocked %s: it can't sign up or sign in.", email)
}

func (e Env) unblock(ctx context.Context, email string) error {
	changed, err := e.Store.UnblockEmail(ctx, email, e.Actor, e.Now())
	if err != nil {
		return err
	}
	if !changed {
		return e.say("%s is not blocked; nothing changed.", email)
	}
	if u, err := e.Store.UserByEmail(ctx, email); err == nil && !u.SuspendedAt.IsZero() {
		return e.say("Unblocked %s. Its account is still suspended; to lift that, run: relay account unsuspend %s", email, email)
	}
	return e.say("Unblocked %s.", email)
}

const day = "2006-01-02"

func (e Env) blocked(ctx context.Context) error {
	list, err := e.Store.BlockedEmails(ctx)
	if err != nil {
		return err
	}
	if len(list) == 0 {
		return e.say("No addresses are blocked.")
	}
	w := tabwriter.NewWriter(e.Out, 0, 0, 2, ' ', 0)
	for _, b := range list {
		if _, err := fmt.Fprintf(w, "%s\tblocked %s\t%s\n", b.Email, b.At.UTC().Format(day), b.Reason); err != nil {
			return err
		}
	}
	return w.Flush()
}

func (e Env) accounts(ctx context.Context) error {
	list, err := e.Store.Accounts(ctx, e.Now())
	if err != nil {
		return err
	}
	if len(list) == 0 {
		return e.say("No accounts.")
	}
	w := tabwriter.NewWriter(e.Out, 0, 0, 2, ' ', 0)
	if _, err := fmt.Fprintln(w, "EMAIL\tCREATED\tLAST SIGN-IN\tSTATUS\tMAC\tCLAUDE APPS"); err != nil {
		return err
	}
	suspended := 0
	for _, a := range list {
		status := "active"
		switch {
		case a.Suspended:
			status = "suspended"
			suspended++
		case !a.Verified:
			status = "unconfirmed" // signed up, never entered the emailed code; removed after a day
		}
		last, mac := "never", "no"
		if !a.LastSignIn.IsZero() {
			last = a.LastSignIn.Format(day)
		}
		if a.HasMac {
			mac = "yes"
		}
		if _, err := fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t%d\n", a.Email, a.CreatedAt.Format(day), last, status, mac, a.Approvals); err != nil {
			return err
		}
	}
	if err := w.Flush(); err != nil {
		return err
	}
	noun := "accounts"
	if len(list) == 1 {
		noun = "account"
	}
	return e.say("%d %s, %d suspended.", len(list), noun, suspended)
}

// Package operator is the commands for the person running a relay (plan D14, FR-195): list
// accounts, suspend and delete them, block addresses, export an account's trace (FR-685). They are subcommands of the relay binary
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
	"github.com/tonimelisma/latchkey/relay/internal/trace"
)

// Usage lists the commands.
const Usage = `Commands for the person running this relay:

  relay account list                      every account: address, dates, status (no secrets)
  relay account suspend <email> [reason]  sign the account out everywhere, remove Claude's access,
                                          refuse its Mac and its sign-ins; deletes nothing
  relay account unsuspend <email>         lift a suspension
  relay account delete <email>            delete the account and everything stored about it
  relay account recovery-code <email>     a one-time code (one hour) for its owner to make a new
                                          passkey, for a relay without an email server
  relay block <email> [reason]            refuse sign-up and sign-in for an address, and suspend
                                          its account if it has one
  relay unblock <email>                   remove a block (a suspended account stays suspended)
  relay block list                        the blocked addresses
  relay trace export <email> [--from YYYY-MM-DD] [--to YYYY-MM-DD]
                                          the account's full trace, oldest first, one JSON
                                          line per tool call or event (days in UTC, both
                                          included), to standard output

With no command, relay starts the server.
`

// ErrUsage means the arguments aren't a command; the caller prints Usage.
var ErrUsage = errors.New("not a command")

// Env is what a command works with.
type Env struct {
	Store  *store.Store
	Traces *trace.Store     // the accounts' trace files (FR-683); nil: none
	Out    io.Writer        // one plain line per command that changed or found something; an export's lines
	Err    io.Writer        // what an export couldn't read; default io.Discard
	Actor  string           // who runs it, for the operator log
	Now    func() time.Time // default time.Now
}

// Run executes one command. An error means nothing was done (or the command wasn't one,
// ErrUsage); the process should exit non-zero.
func Run(ctx context.Context, env Env, args []string) error {
	if env.Now == nil {
		env.Now = time.Now
	}
	if env.Err == nil {
		env.Err = io.Discard
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
		case "recovery-code":
			return env.withEmail(rest[1:], false, func(email, _ string) error { return env.recoveryCode(ctx, email) })
		}
		return ErrUsage
	case "block":
		if len(rest) == 1 && rest[0] == "list" {
			return env.blocked(ctx)
		}
		return env.withEmail(rest, true, func(email, reason string) error { return env.block(ctx, email, reason) })
	case "unblock":
		return env.withEmail(rest, false, func(email, _ string) error { return env.unblock(ctx, email) })
	case "trace":
		if len(rest) == 0 || rest[0] != "export" {
			return ErrUsage
		}
		return env.traceExport(ctx, rest[1:])
	}
	return ErrUsage
}

// traceExport is `trace export <email> [--from YYYY-MM-DD] [--to YYYY-MM-DD]` (FR-685).
func (e Env) traceExport(ctx context.Context, args []string) error {
	var email, from, to string
	for i := 0; i < len(args); i++ {
		a := args[i]
		name, value, inline := strings.Cut(a, "=")
		switch name {
		case "--from", "--to":
			if !inline {
				if i+1 == len(args) {
					return ErrUsage
				}
				i++
				value = args[i]
			}
			if err := trace.CheckDay(value); err != nil || value == "" {
				return fmt.Errorf("%s: %q is not a day; write it as YYYY-MM-DD", name, value)
			}
			if name == "--from" {
				from = value
			} else {
				to = value
			}
		default:
			if strings.HasPrefix(a, "-") || email != "" {
				return ErrUsage
			}
			email = a
		}
	}
	if email == "" {
		return ErrUsage
	}
	return e.withEmail([]string{email}, false, func(email, _ string) error {
		u, err := e.Store.UserByEmail(ctx, email)
		if err != nil {
			return noAccount(email, err)
		}
		if e.Traces == nil {
			return errors.New("this relay keeps no traces")
		}
		skipped, err := e.Traces.Export(u.ID, u.Email, from, to, e.Out)
		if err != nil {
			return err
		}
		switch skipped {
		case 0:
		case 1:
			_, _ = fmt.Fprintln(e.Err, "1 line couldn't be read and was left out.")
		default:
			_, _ = fmt.Fprintf(e.Err, "%d lines couldn't be read and were left out.\n", skipped)
		}
		return nil
	})
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

// recoveryCode gives the Owner of a relay without an email server a way back in (spec 009
// FR-914): the code works on the relay's "Lost your passkey?" page, once, for an hour.
func (e Env) recoveryCode(ctx context.Context, email string) error {
	now := e.Now()
	code, err := account.RecoveryCode(ctx, e.Store, email, now)
	if err != nil {
		return noAccount(email, err)
	}
	until := now.Add(account.RecoveryCodeLifetime).UTC().Format("15:04")
	return e.say("Recovery code for %s: %s (works once, until %s UTC). On the relay's page, choose \"Lost your passkey?\" and enter it.", email, code, until)
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
	u, err := e.Store.DeleteUserByOperator(ctx, email, e.Actor, e.Now())
	if err != nil {
		return noAccount(email, err)
	}
	if err := e.Traces.Delete(u.ID); err != nil { // FR-687
		return fmt.Errorf("deleted %s, but its traces couldn't be removed (%w); remove the folder traces/%s in the relay's data folder", email, err, u.ID)
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

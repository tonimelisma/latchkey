package account

import (
	"fmt"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

func emailVerifyCode(code string) string {
	return fmt.Sprintf(`Your Latchkey code is:

    %s

Enter it on the sign-in page to finish setting up your account. It expires in 15 minutes.

If you didn't try to sign up for Latchkey, you can ignore this email.
`, code)
}

func emailRecoverCode(code string) string {
	return fmt.Sprintf(`Your Latchkey recovery code is:

    %s

Enter it on the sign-in page to create a new passkey. Your old passkeys will stop working once you
do, and Claude will need to connect again. The code expires in 15 minutes.

If you didn't ask for this, ignore this email. Nothing changes unless the code is used.
`, code)
}

// The security emails (FR-696 to FR-699) say what happened, when, where the request came from,
// and what to do if it wasn't the Owner. They never hold a code, a token, or a key.

// alertEmail is one security email, and which change it reports (for the log).
type alertEmail struct {
	what, subject, body string
}

func alertTime(at time.Time) string { return at.UTC().Format("Jan 2, 2006 at 3:04 PM") + " UTC" }

// alertFrom names the client's address, when the relay knows it.
func alertFrom(ip string) string {
	if ip == "" {
		return ""
	}
	return " The request came from the IP address " + ip + "."
}

const alertWhy = "Latchkey emails you whenever a machine is connected to your account, an app is allowed to use your machines, or your account is recovered.\n"

// emailMachinePaired is FR-696.
func emailMachinePaired(kind, name string, at time.Time, ip, account, recover string) alertEmail {
	what := "A Mac"
	if kind == store.KindLinux {
		what = "A Linux server"
	}
	return alertEmail{what: "machine connected", subject: what + " was connected to your Latchkey account", body: fmt.Sprintf(`%s named “%s” was connected to your Latchkey account on %s.%s

Claude can now use the tools that are turned on in Latchkey on it.

If this was you, there's nothing to do.

If it wasn't you, remove it on your account page right away (%s), then recover your account (%s): that replaces your passkeys and signs out every browser.

%s`, what, name, alertTime(at), alertFrom(ip), account, recover, alertWhy)}
}

// emailAppAllowed is FR-697: the app and where the approval went, as the consent page showed them.
func emailAppAllowed(app, redirectHost string, at time.Time, ip, account, recover string) alertEmail {
	sentBack := ""
	if redirectHost != "" {
		sentBack = " The approval was sent back to " + redirectHost + "."
	}
	return alertEmail{what: "app allowed", subject: "An app was allowed to use your Latchkey machines", body: fmt.Sprintf(`The app “%s” was allowed to use your machines on %s.%s%s

It can see which of your machines are online and use the tools you've turned on in Latchkey on each one.

If this was you, there's nothing to do.

If it wasn't you, remove its access on your account page right away (%s), then recover your account (%s): that replaces your passkeys and signs out every browser.

%s`, app, alertTime(at), sentBack, alertFrom(ip), account, recover, alertWhy)}
}

// emailRecovered is FR-698.
func emailRecovered(at time.Time, ip, account, recover string) alertEmail {
	return alertEmail{what: "account recovered", subject: "Your Latchkey account was recovered", body: fmt.Sprintf(`Your Latchkey account was recovered on %s.%s A new passkey was created, your old passkeys were removed, every browser was signed out, and Claude's access was removed.

If this was you, Claude will ask you to connect again the next time you use Latchkey.

If it wasn't you, recover your account again right away (%s), then check your account page (%s) and remove anything you don't recognize.

%s`, alertTime(at), alertFrom(ip), recover, account, alertWhy)}
}

package account

import (
	"fmt"
	"time"
)

func emailVerify(link string) string {
	return fmt.Sprintf(`Open this link to create your passkey and finish setting up Latchkey:

%s

The link works once and expires in 15 minutes.

If you didn't sign up for Latchkey, you can ignore this email.
`, link)
}

func emailAlreadyRegistered(signin, recover string) string {
	return fmt.Sprintf(`Someone, probably you, tried to create a Latchkey account with this email address. You already have one.

Sign in with your passkey: %s

Lost your passkeys? Recover your account: %s
`, signin, recover)
}

func emailRecover(link string) string {
	return fmt.Sprintf(`Open this link to create a new passkey for your Latchkey account:

%s

Your old passkeys will stop working once you do. The link works once and expires in 15 minutes.

If you didn't ask for this, ignore this email. Nothing changes unless the link is used.
`, link)
}

func emailRecovered(at time.Time, recover, account string) string {
	return fmt.Sprintf(`Your Latchkey account was recovered on %s UTC. A new passkey was created and your old passkeys were removed.

If this was you, there's nothing else to do.

If it wasn't you, recover your account again right away (%s), then check your account page (%s) and disconnect anything you don't recognize.
`, at.UTC().Format("Jan 2, 2006 at 3:04 PM"), recover, account)
}

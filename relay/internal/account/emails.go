package account

import (
	"fmt"
	"time"
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

func emailRecovered(at time.Time, recover, account string) string {
	return fmt.Sprintf(`Your Latchkey account was recovered on %s UTC. A new passkey was created, your old passkeys were removed, and Claude's access was removed.

If this was you, Claude will ask you to connect again the next time you use Latchkey.

If it wasn't you, recover your account again right away (%s), then check your account page (%s) and disconnect anything you don't recognize.
`, at.UTC().Format("Jan 2, 2006 at 3:04 PM"), recover, account)
}

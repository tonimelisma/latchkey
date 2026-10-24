# Security

Latchkey lets Claude act on a Mac, so security problems in it matter. Thank you for reporting
them privately.

## Reporting a vulnerability

Use GitHub's private reporting: on this repository, open the **Security** tab and choose
**Report a vulnerability**. Only you and the maintainer see the report. Please don't open a
public issue, pull request, or discussion about an unfixed problem.

A useful report says:

- what is affected (the relay, the Mac app, the keep-awake helper, or the protocol between them)
  and which version or commit;
- how to reproduce it, step by step, and what an attacker gains;
- anything you've found about how to fix it.

You'll get a reply within a week, and updates as the fix progresses. Once a fix is released, you
can publish your findings; you'll be credited unless you'd rather not be.

## Supported versions

Only the latest release of the Mac app and the latest commit of the relay get security fixes.

## What's in scope

- Getting into someone else's account, Mac, or Claude connection; getting tokens or keys that
  aren't yours.
- Making the Mac run a tool its owner turned off, or a tool at a higher level than allowed.
- Anything that lets the relay, a network attacker, or another app on the Mac misuse the
  connection, the device key, or the keep-awake helper (which runs as root).
- Getting data the relay is not supposed to keep, or reading another user's data on a shared relay.
- Weaknesses in sign-in, passkeys, email codes, OAuth, or pairing.

## Known limits (not vulnerabilities by themselves)

- **Prompt injection.** Text written by others (messages, web pages, files) can try to steer
  Claude. Latchkey marks such text as content, not instructions, but it can't stop Claude from
  following it within the capabilities the owner turned on. See `docs/best-practices.md`. A way
  around Latchkey's own protections (for example, text that removes the marking) is in scope.
- **A compromised Claude account or relay can use whatever the owner turned on.** The Mac enforces
  its levels itself, so it can't use what's off.
- **Computer control needs an unlocked Mac.** Latchkey never types the Mac's password.

## How Latchkey protects you

The design and its reasons are in `docs/best-practices.md` and `specs/`. In short:

- The Mac connects out to the relay; nothing listens on the Mac.
- Each capability is Off, Read only, or Read & write on the Mac itself; a capability that's off
  doesn't exist for Claude, and the Mac rejects calls to it.
- Sign-in uses passkeys; Claude gets OAuth tokens issued for this relay only; the Mac proves
  itself with a key kept in the Secure Enclave.
- The relay never stores what tools return; its log keeps which tool ran and when, for 30 days.
  The full activity log stays on the Mac.
- Every change Claude makes shows a notification on the Mac, and so does every new Claude
  connection.

## Testing

Test only against a relay and a Mac you own. Don't test against other people's accounts or the
hosted relay's users, and don't degrade the hosted relay for others.

# 0006. Owner authentication: passkeys only, email recovery

- Status: accepted
- Date: 2026-10-19
- Alias: plan 001 D5 (`specs/001-core/plan.md`, "D5. Owner authentication: passkeys only, email recovery")

## Context and problem

Decision D5 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-041, FR-042, FR-043, FR-696, FR-699a, FR-043a, FR-046, FR-048, FR-042a, FR-047, FR-047a, FR-099, FR-047b, FR-042b, FR-699, FR-082, FR-080.
The design it belongs to: [design/core.md](../design/core.md).

## Decision

Serves FR-041, FR-042, FR-043, FR-696 to FR-699a.
- `github.com/go-webauthn/webauthn` (BSD-3), discoverable credentials, user verification required.
- One sign-in page (FR-043a), email first: a verified account with passkeys continues with its
  passkey; a new account gets a 6-digit code by email (15 minutes, 5 wrong attempts, stored hashed
  with the user ID), then creates a passkey. Recovery is the same with a recovery code. The email
  field also offers saved passkeys through WebAuthn conditional mediation (autofill). Codes keep
  the whole journey in one window, so the Mac app's sign-in window never sends the Owner to
  another tab. Sign-up is open unless `ALLOWED_EMAILS` is set (FR-046).
- Web sessions: an HTTP-only, Secure, SameSite=Lax cookie holding a random ID stored hashed;
  30 days (FR-048). Account deletion requires a fresh passkey assertion. Forms carry a CSRF token
  tied to the session. Every JSON endpoint of the sign-in page, including the passkey finish
  steps that start a session, accepts only `Content-Type: application/json`, which a cross-site
  page cannot send without a CORS preflight the relay never answers (no login CSRF).
- After sign-in the page returns only to a path on the relay itself: the `next` value must parse
  with no scheme or host, start with a single `/`, and contain no control character or backslash
  (browsers drop the first and read the second as `/`); otherwise `/account`. The page's script
  checks the same origin again before navigating (security scan, 2026-10-24).
- Wrong codes (FR-042, FR-042a): checking a code, counting a wrong one, and using a right one
  happen in one `BEGIN IMMEDIATE` transaction, so concurrent guesses cannot get past the
  5-attempt limit and a code is used once. Each address also counts wrong codes per day on its
  `users` row (`wrong_codes`, `wrong_codes_since`, migration 5); new codes don't reset it. After
  20 within a day of the first, every emailed code for the address is refused (HTTP 429, "Too
  many wrong codes were entered for this email address today. Sign in with your passkey, or try
  again tomorrow.") and no new code is emailed until 24 hours after that first wrong code;
  passkey sign-in is unaffected. Options weighed: a separate table of wrong-code times (more
  rows, sliding window) or carrying the attempt count over to the next code (still unbounded
  across days); two columns on `users` are the smallest change that bounds a day.
- Recovery: single-use code, 15 min expiry, stored hashed; completing it removes all old passkeys
  (FR-047), signs out every browser, and removes every Claude client's access (its codes and
  tokens), as "Remove Claude's access" does (FR-047a); the recovery page and
  emails say Claude must connect again. Using it is announced by email (a security email,
  below) and in the Mac app. The Mac app learns of it through a `notice` message (contracts/agent-protocol.md), sent
  at once if the Mac is online, otherwise on its next connection (the relay compares the
  recovery's `used_at` with the device's last connection; nothing new is stored).
- Sign-ins in progress (security review, 2026-10-25). A passkey exchange (5 minutes) and the
  ticket a confirmed code gives (10 minutes) live in memory between two requests. Each table is
  capped at 10,000 entries (FR-099): a further one gets HTTP 503 with `Retry-After: 60` and "Too
  many sign-ins are in progress right now. Try again in a minute." Expired entries are swept at
  most once a minute, and whenever a table is full, instead of on every insert. A ticket is
  taken in the same step that checks it, when the passkey registration finishes, so two
  registrations started from one ticket can't both complete; it is put back if that attempt
  fails before a passkey is saved, so the Owner can retry without a new code. When a
  registration completes, every other ticket and pending registration of the account is
  dropped (FR-047b), so a ticket from an earlier recovery code can't add a passkey afterwards
  and, by completing a second recovery, remove the Owner's new one. Options weighed for the
  cap: evicting the oldest entry when full (lets a flood cancel real sign-ins in progress) or
  refusing new ones (chosen: a flood only delays new sign-ins for up to five minutes).
- Recovery requests answer before the email is sent (FR-042b): for a known account the code is
  stored and mailed in a background task (at most 16 at once, 30 s each, failures logged), so
  the answer takes the same time as for an unknown address, where nothing is sent. Before, the
  request waited on the mail server only when the account existed. A send that fails can't be
  reported to the page without revealing the account; the page already tells the Owner to ask
  again if no email arrives.
- Security emails (FR-696 to FR-699; decided 2026-11-21), the same way: `account/alerts.go`
  sends one after a Mac's `POST /pair/exchange`, a Linux server's confirmed `POST /link`, the
  consent page's Allow (oauth's `OnAuthorized`, which now passes the redirect host the page
  showed, and which a code exchange or refresh never calls), and a completed recovery. The
  recovery email, which until now was sent before the passkey step answered, goes the same
  way. Each is handed to a background task (at most 16 at once, 30 s each, its own slots apart
  from the recovery codes'), which looks up the address and sends; a failure is logged with the
  change and the account's ID, never the address or the IP. Limits, in memory: 10 per account
  at once, then one every 6 minutes (several machines and Claude apps set up in one sitting
  fit; a flood shows as ten emails), and 100 from the relay at once, then one every 30 s, apart
  from the codes' relay-wide allowance so a flood of sign-up codes can't silence them. They
  can only go to an account's own confirmed address, after a signed-in or code-confirmed
  action, so they can't be aimed at a stranger. The IP: the guard puts `ClientAddress` (the
  FR-082 address, an IPv6 one whole, not grouped by /64 as the limits do) on the request's
  context (`limit.WithAddress`), so the account and OAuth handlers need no proxy settings of
  their own; it appears only in the email, never in the database or the log. At shutdown the
  relay waits for sends in progress, within its 10 s (`Relay.DrainMail`). Options weighed:
  sending in the request (Constitution II: the change would wait on the mail server); sharing
  the codes' per-address limit (one a minute would swallow the recovery email sent right after
  its code); a queue in the database that survives a restart (a new table and its privacy text
  for a 30-second window; not worth it).
- No account can silence another's security email (FR-699a; security review, 2026-11-21: with
  open sign-up, an attacker's own accounts could empty the one relay-wide bucket by pairing
  their own machines, then take over a victim's account unreported). Each account also has a
  reserve, 3 at once and one back every 2 hours (3 in any 6 hours). A reserve-covered email is
  paid from a second relay-wide bucket, 300 at once and one every 10 s, that ordinary emails
  never touch, so a flood of them can't drain it, and all accounts' reserves together stay
  bounded (review: a reserve with no relay-wide ceiling let many accounts' reserves add up
  without limit, bad for the sending domain's reputation). Past it, a reserve-covered email
  falls back to the ordinary bucket, so the victim gets two chances; past both it isn't sent.
  Draining the reserved bucket takes 100 confirmed accounts' reserves at once, and each new
  account needs an emailed sign-up code from the codes' own allowance. The decision is made
  under one lock: the account's bucket first (`Keyed.HasAt`, which takes nothing), then the
  waiting cap, then the relay-wide buckets; the account's token and reserve are spent only when
  the email will go, so a refusal costs the account nothing. Sending: 16 slots, 4 of them only
  for reserve-covered emails (which may also take the other 12), so other accounts' ordinary
  emails can't hold every slot. An email waits up to 30 s for a slot, and its own 30 s to send
  start once it holds one (two deadlines, so a long wait doesn't eat the send). At most 256 of
  each kind wait (accepted, not yet holding a slot; at most 540 tasks in all); one more is
  dropped. Every refusal that isn't the account's own doing is logged at Error with a fixed
  message for the operator's alarm: "security email not sent: relay-wide limit reached",
  "... relay-wide limit for reserved emails reached", "... too many waiting to be sent", "...
  no sending slot in time". Options weighed: a bigger single relay-wide bucket (only raises
  what an attacker must spend); a relay-wide bucket per IP address (the attacker's accounts can
  use many addresses); charging reserved emails to the ordinary bucket and letting them go a
  bounded amount over (the overdraft is drained by the same flood); no relay-wide limit for
  security emails at all (nothing would bound the provider's quota).
- Email: SMTP via `github.com/wneessen/go-mail`; configured by environment variables (FR-080).
  The hosted relay sends through Resend's SMTP from `no-reply@` its own host name. Mail is always
  encrypted: TLS from the start on port 465, required STARTTLS on other ports (a server that
  doesn't offer it gets nothing, so an on-path attacker can't strip it and read codes); only a
  server on loopback (a local test mail catcher) may be plain (security scan, 2026-10-24).
- Web pages: server-rendered `html/template` with a small script for WebAuthn calls, and one small
  hand-written stylesheet (system font, light and dark) embedded in the binary. No frontend
  framework, no CSS library.

## Confirmation

The tests that validate the requirements it cites:

- `relay/internal/account/account_test.go`
- `relay/internal/account/alerts_test.go`
- `relay/internal/limit/limit_test.go`
- `relay/internal/server/alerts_test.go`
- `relay/internal/server/guard_test.go`
- `relay/internal/store/signin_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

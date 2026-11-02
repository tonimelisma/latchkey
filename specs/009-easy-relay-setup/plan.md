# Plan 009: Easy relay setup — HOW

Derived from `spec.md` (Toni, 2026-10-31: "continue" after its open questions were answered);
evidence in `research.md`. Every decision names the requirements it serves. Built in this order
(Toni, 2026-10-31): the relay (D1–D6), then the guide tested on Google Cloud (D7, D8), then the
Mac app's choice (D9).

## D1. Sign-up with a setup code, no email server (FR-907, FR-908)

- New setting `SETUP_CODE`. `SMTP_HOST` and `SMTP_FROM` stop being required when `SETUP_CODE` is
  set; the relay refuses to start with neither (it would have no way to let anyone in).
- With `SETUP_CODE` set and no account yet, the sign-up page asks for an email address and the
  code. The code is compared in constant time; a match counts as a verified email (it takes the
  place of the emailed code, `authCode`), and the passkey ceremony follows as today. Wrong codes
  go through the existing abuse limits (per address and per visitor).
- Once any account exists, the code no longer opens sign-up, and the page says sign-up is
  closed. With an email server also configured, the relay works as today for everyone else
  (`ALLOWED_EMAILS` decides who).
- The code is a setting, not stored: the user table is the record that it was used. No schema
  change. Options were (a) this; (b) a stored one-time code, which needs a table and a way to
  make it; (c) first visitor wins (Immich), refused: a fresh relay on a public address could be
  claimed by anyone who finds it first.

## D2. Recovery code from the operator (FR-914)

- New operator command `relay account recovery-code <email>`, run inside the container (on the
  default host: `gcloud compute ssh` then `sudo podman exec latchkey-relay /relay account
  recovery-code <email>`). It makes the same kind of code the relay emails for "Lost your
  passkey?" today, stores it the same way (hashed, single use), and prints it; lifetime 1 hour
  instead of the emailed code's 15 minutes, since it passes through a person and Claude Code.
- Without an email server, "Lost your passkey?" asks for the email address and goes straight to
  the code step ("Enter the recovery code you were given"), sending nothing. The existing code
  step then lets the person make a new passkey for the same account, as email recovery does
  (plan 001 D5): the Mac's pairing and the records stay; the old passkeys stop working and
  Claude's apps sign in again.
- Using it is recorded as recovery is today (event `account_recovered`, FR-631), and the Mac is
  told on its next connection (existing notice).

## D3. Readiness for update rollback (FR-909)

- When `NOTIFY_SOCKET` is set (systemd, and Podman's Quadlet with `Notify=true`), the relay sends
  `READY=1` once its database is open and its listener accepts connections, and `STOPPING=1` on
  shutdown. A few lines over a Unix datagram socket; no library. `podman auto-update` restarts
  the unit with the new image and rolls back when the unit fails to become ready.
- Options were (a) sd_notify, chosen: works with Ubuntu 24.04's Podman 4.9; (b) Quadlet's
  `Notify=healthy` with the image's health check, which needs Podman 5; (c) nothing: a relay
  that crashes after starting would not be rolled back.

## D4. A copy of the database before a schema change (FR-909)

- At start, when goose reports pending migrations, the relay writes `VACUUM INTO
  /data/backups/relay-<UTC date>-<from version>.db` first, keeps the newest three, and logs the
  file. Going back to an older image means stopping the relay and putting that copy in place
  (docs/self-hosting.md says how); the key file is unchanged by migrations.

## D5. Session cookie bound to the host (FR-912)

- Already the case (found while building, 2026-10-31): on HTTPS the session cookie is named
  `__Host-latchkey_session` (Path `/`, no Domain, Secure), so no other site under a shared parent
  name (sslip.io) can set or read it; over plain HTTP (local development) it is
  `latchkey_session`. Nothing to change, and no one is signed out.

## D6. Public images with every deploy (FR-911)

- `deploy/deploy.sh` builds `linux/amd64` and `linux/arm64` with `docker buildx` and pushes
  `ghcr.io/tonimelisma/latchkey-relay:<git short hash>` and `:latest`, after the security checks
  and before the server is updated (Toni, 2026-10-31: "with every deploy"); the server still
  gets the amd64 image as today. A push failure stops the deploy.
- The registry login uses the GitHub CLI's token (`gh auth token`), which needs the
  `write:packages` scope: a one-time `gh auth refresh -s write:packages` (Toni clicks Allow in
  the browser). The first push creates the package as private; it is made public once in the
  package's settings on GitHub (Toni's one click; unverified whether the API can do it).
- `relay/Dockerfile` already cross-compiles for the target platform.

## D7. The guide (FR-901, FR-902, FR-904, FR-905, FR-906, FR-910)

- `docs/setup-with-claude.md` (in the plugin from spec 011 until it was withdrawn, 2026-11-01) as drafted: Google Cloud's free e2-micro in us-central1-a (other
  US zones if unavailable), Ubuntu 24.04, a reserved static address, firewall open on 443 only,
  the relay's own Let's Encrypt certificate (TLS-ALPN on 443), name `<ip-with-dashes>.sslip.io`,
  Podman Quadlet with `AutoUpdate=registry` and `Notify=true`, `podman-auto-update.timer`, a $1
  budget alert, and the setup code from D1. Steps say what Claude says, runs, and checks.
- The guide is fetched by its public raw URL (the repository is public, 2026-10-31).

## D8. Testing the guide (SC-902, SC-903)

- Claude Code runs the guide for real in a new project in Toni's Google account (Toni,
  2026-10-31), checks the relay answers with a valid certificate, claims it with the setup code
  through headless Chrome (a virtual passkey, as the relay's browser test does), pairs a
  stand-in Mac (the relay's test agent), and calls a tool through a fresh Claude Code session
  pointed at it. Then it publishes a test image tag, watches `podman auto-update` take it, and
  pushes a broken one to see the rollback. Last, the project is deleted.
- Toni's billing account already uses its free e2-micro (the hosted relay), so the test server is
  billed: about $0.01 an hour, cents in all. The fresh-account questions (address charge, trial
  upgrade) stay open in the guide until someone runs it on a new account.

## D9. "Set one up with Claude" in the Mac app (FR-903)

- In setup's first step, under the relay address field: "Don't have a relay? Claude can set one
  up for you." with a Copy Request button. The request: "Set up a Latchkey relay for me. Follow
  the instructions at https://raw.githubusercontent.com/tonimelisma/latchkey/main/docs/setup-with-claude.md".
  A line says to paste it into Claude Code (the Code tab in Claude Desktop). Wording and layout
  reviewed against Apple's guidelines; README picture redrawn.

## Contracts and data

- No change to the relay–Mac protocol or the MCP surface. New operator command (D2) and settings
  (`SETUP_CODE`, D1) documented in docs/self-hosting.md, which also describes every default the
  guide picks as a setting a technical operator changes (FR-913). No new table; the cookie name (D5) and
  backup files (D4) are listed in data-model.md's "stored on the server" notes.

## Tests (written first)

- Relay: sign-up with the right code, a wrong code (limited), after an account exists (closed),
  with and without an email server; start refused with neither; recovery code made by the
  command, used once, expired after an hour, refused twice; recovery page without email sends
  nothing; `READY=1` and `STOPPING=1` on a test socket; backup written only when migrations are
  pending, three kept; cookie name on HTTPS and HTTP; the headless-Chrome flow claims a relay
  with a code and a virtual passkey.
- Deploy: `deploy/tests` for the image tags and the refusal to deploy when the push fails.
- Guide: D8, end to end on Google Cloud.
- App: the setup view renders the new choice; the copied request contains the guide's URL.

## Constitution check

| Principle | Result |
|---|---|
| I. No inbound connections | Pass: the Mac still only connects out |
| II. Fail fast | Pass: no new waits on the Mac; the relay's ready signal is sent once, without waiting |
| III. Disabled means nonexistent | Pass: no tool changes |
| IV. Good macOS citizen | Pass: one button and copied text; nothing installed on the Mac by the app |
| V. Self-hostable | Pass, strengthened: a relay without an email server or domain; every default a setting |
| VI. Store the minimum | Pass: the setup code isn't stored; database copies stay on the Owner's own server, three kept |
| VII. Test-first | Pass: tests above first; the guide tested for real |
| VIII. Simplicity | Pass: no new dependencies (sd_notify by hand; Podman and gcloud on the host, not in the code) |
| IX. Open source | Pass: public repository and images |

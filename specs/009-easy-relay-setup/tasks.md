# Tasks 009: Easy relay setup

From `plan.md`. Tests first in every task; `[P]` tasks touch different files and can run side by
side. Order: relay (T1–T7), guide (T8–T9), app (T10), wrap-up (T11).

## Relay

- **T1** Setup code (D1, FR-907, FR-908): tests for sign-up with the right code, a wrong code
  (limited), after an account exists (closed), with and without an email server, and start
  refused with neither; then `SETUP_CODE` in config, the sign-up page's code field, and the
  check in place of the emailed code. Files: `relay/cmd/relay/config.go`,
  `relay/internal/account/`, templates.
- **T2** Recovery code (D2, FR-914): tests for the command making a code, one use, expiry after an
  hour, the recovery page without email sending nothing; then `relay account recovery-code
  <email>` and the no-email recovery step. Files: `relay/internal/operator/`,
  `relay/internal/account/`. After T1 (shares the account code).
- **T3** [P] Ready signal (D3, FR-909): tests with a test Unix socket for `READY=1` after the
  listener is up and `STOPPING=1` on shutdown; then the sender. Files: `relay/cmd/relay/`
  (a new small file).
- **T4** [P] Database copy before migrations (D4, FR-909): tests that a copy is written only when
  migrations are pending and that three are kept; then the copy in `relay/internal/store/`.
- **T5** Host-bound cookie (D5, FR-912): already in place (`__Host-latchkey_session` on HTTPS);
  nothing to do.
- **T6** Browser test (D1, D8): the headless-Chrome test claims a fresh relay with a setup code
  and a virtual passkey, and recovers with a recovery code. Files: `relay/internal/e2e/`.
- **T7** Images with every deploy (D6, FR-911): `deploy/tests` for tags and the refusal on a failed
  push; then the buildx multi-platform push in `deploy/deploy.sh`. Needs Toni once:
  `gh auth refresh -s write:packages` and making the package public on GitHub.

## Guide

- **T8** Docs (D1, D2, D7, FR-913): docs/self-hosting.md gains `SETUP_CODE`, the recovery command,
  running without an email server, the backups (D4), and each guide default as a setting;
  docs/setup-with-claude.md final.
- **T9** Real run on Google Cloud (D8, SC-902, SC-903): a new project in Toni's account; relay up
  with a valid certificate; claimed through headless Chrome; a stand-in Mac paired; a tool called
  by a fresh Claude Code session; an image update taken and a broken one rolled back; project
  deleted. Findings go into the guide.

## App

- **T10** "Set one up with Claude" (D9, FR-903): render test and copied-text test; then the choice
  in `SetupView`; README picture redrawn (`macos/scripts/readme-shots.sh`); app version bumped
  and installed.

## Wrap-up

- **T11** STATUS, decisions, README; deploy the relay (the cookie change signs everyone out once:
  say so); live check.

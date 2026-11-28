# Easy relay setup: design

GOVERNS: `docs/setup-with-claude.md` `relay/cmd/relay/`

Spec 009's plan (migrated from `specs/009-easy-relay-setup/plan.md`, titled "Plan 009: Easy relay setup — HOW"). What it must do:
[requirements/easy-relay-setup.md](../requirements/easy-relay-setup.md). Each decision Dn is an ADR, linked
where the decision stood.

Derived from `docs/requirements/easy-relay-setup.md` (decided 2026-10-31: "continue" after its open questions were answered);
evidence in `docs/research/2026-10-31-easy-relay-setup.md`. Every decision names the requirements it serves. Built in this order
(decided 2026-10-31): the relay (D1–D6), then the guide tested on Google Cloud (D7, D8), then the
Mac app's choice (D9).

## D1. Sign-up with a setup code, no email server (FR-907, FR-908)

Decision record: [ADR 0103](../adr/0103-sign-up-with-a-setup-code-no-email-server.md).

## D2. Recovery code from the operator (FR-914)

Decision record: [ADR 0104](../adr/0104-recovery-code-from-the-operator.md).

## D3. Readiness for update rollback (FR-909)

Decision record: [ADR 0105](../adr/0105-readiness-for-update-rollback.md).

## D4. A copy of the database before a schema change (FR-909)

Decision record: [ADR 0106](../adr/0106-a-copy-of-the-database-before-a-schema-change.md).

## D5. Session cookie bound to the host (FR-912)

Decision record: [ADR 0107](../adr/0107-session-cookie-bound-to-the-host.md).

## D6. Public images with every deploy (FR-911)

Decision record: [ADR 0108](../adr/0108-public-images-with-every-deploy.md).

## D7. The guide (FR-901, FR-902, FR-904, FR-905, FR-906, FR-910)

Decision record: [ADR 0109](../adr/0109-the-guide.md).

## D8. Testing the guide (SC-902, SC-903)

Decision record: [ADR 0110](../adr/0110-testing-the-guide.md).

## D9. "Set one up with Claude" in the Mac app (FR-903)

Decision record: [ADR 0111](../adr/0111-set-one-up-with-claude-in-the-mac-app.md).

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

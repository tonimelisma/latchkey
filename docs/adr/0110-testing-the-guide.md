# 0110. Testing the guide (SC-902, SC-903)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 009 D8 (`specs/009-easy-relay-setup/plan.md`, "D8. Testing the guide (SC-902, SC-903)")

## Context and problem

Decision D8 of spec 009's plan (Easy relay setup); requirements in
[requirements/easy-relay-setup.md](../requirements/easy-relay-setup.md). Requirement IDs it cites: SC-902, SC-903.
The design it belongs to: [design/easy-relay-setup.md](../design/easy-relay-setup.md).

## Decision


- Claude Code runs the guide for real in a new project in the maintainer's Google account (decided
  2026-10-31), checks the relay answers with a valid certificate, claims it with the setup code
  through headless Chrome (a virtual passkey, as the relay's browser test does), pairs a
  stand-in Mac (the relay's test agent), and calls a tool through a fresh Claude Code session
  pointed at it. Then it publishes a test image tag, watches `podman auto-update` take it, and
  pushes a broken one to see the rollback. Last, the project is deleted.
- The maintainer's billing account already uses its free e2-micro (the hosted relay), so the test server is
  billed: about $0.01 an hour, cents in all. The fresh-account questions (address charge, trial
  upgrade) stay open in the guide until someone runs it on a new account.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

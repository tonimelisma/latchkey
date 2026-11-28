# 0170. The prepared image (FR-1512, FR-1513)

- Status: accepted
- Date: 2026-11-24
- Alias: plan 015 D6 (`specs/015-e2e-evals/plan.md`, "D6. The prepared image (FR-1512, FR-1513)")

## Context and problem

Decision D6 of spec 015's plan (End-to-end tests and evals); requirements in
[requirements/e2e-evals.md](../requirements/e2e-evals.md). Requirement IDs it cites: FR-1512, FR-1513.
The design it belongs to: [design/e2e-evals.md](../design/e2e-evals.md).

## Decision

`macos/scripts/eval-image.sh`, once, from any clone: pulls the base image (research.md decision
4b), installs Chrome's headless shell, Claude Code and the newest Latchkey release, makes the
test certificate authority and trusts it in the test Mac, creates the relay's account and the
pairing (`e2e prepare`, inside the copy), creates the test data sets with `e2e fixture`, asks
for the Claude token at a password prompt (into the login keychain), then opens the VM's window
once for the person to click Connect and approve Latchkey's permissions (Full Disk Access,
Automation, Accessibility, Screen Recording; Screen Recording can only be approved by hand), and
shuts it down. The weekly run checks the permissions first and reports `missing_permissions`
instead of failing tasks (FR-1513). Done again only after a new macOS or a signature change.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

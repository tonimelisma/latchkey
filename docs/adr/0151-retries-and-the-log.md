# 0151. Retries and the log (FR-1324 withdrawn, FR-1327)

- Status: withdrawn (the decision text says why; kept as the record)
- Date: 2026-11-22
- Alias: plan 013 D7 (`specs/013-sign-in/plan.md`, "D7. Retries and the log (FR-1324 withdrawn, FR-1327)")

## Context and problem

Decision D7 of spec 013's plan (Signing in); requirements in
[requirements/sign-in.md](../requirements/sign-in.md). Requirement IDs it cites: FR-1327.
The design it belongs to: [design/sign-in.md](../design/sign-in.md).

## Decision


No cap (decided 2026-11-22: "No cap"): Claude decides whether to try again. A code from Passwords is
still typed once per 30-second step. Every fill goes into the activity log (site, user name, what
was typed and where the code came from, the button, the browser), never the secret.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

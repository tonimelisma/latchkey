# 0161. Name and hosting (FR-1426)

- Status: accepted
- Date: 2026-11-23
- Alias: plan 014 D4a (`specs/014-feedback-intake/plan.md`, "D4a. Name and hosting (FR-1426)")

## Context and problem

Decision D4a of spec 014's plan (Problem reports to the developer); requirements in
[requirements/feedback-intake.md](../requirements/feedback-intake.md). Requirement IDs it cites: FR-1426.
The design it belongs to: [design/feedback-intake.md](../design/feedback-intake.md).

## Decision


The intake runs on the developer's own server, which is run outside this repository, at
`latchkey-feedback.melisma.net` (its DNS record made 2026-11-23), with an ordinary certificate
for that one name. Its deployment lives with that server's, in a private repository; this repository holds the program and its image workflow. The relays' default intake
address is that name.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

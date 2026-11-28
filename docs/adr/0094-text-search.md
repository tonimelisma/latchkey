# 0094. Text search (FR-802)

- Status: accepted
- Date: 2026-10-29
- Alias: plan 008 D4 (`specs/008-mail/plan.md`, "D4. Text search (FR-802)")

## Context and problem

Decision D4 of spec 008's plan (Mail); requirements in
[requirements/mail.md](../requirements/mail.md). Requirement IDs it cites: none current.
The design it belongs to: [design/mail.md](../design/mail.md).

## Decision


No copy of mail is kept (decided 2026-10-29). `text` runs the other filters' query newest first
in batches and reads each message's file, stopping at the requested number of hits or after
20 seconds (`searchBudget`), whichever comes first. The answer says the date of the oldest
message it read and, when it stopped early, to call again with `until` set to that date to look
further back. Messages whose text isn't on the Mac are counted and named in the answer.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

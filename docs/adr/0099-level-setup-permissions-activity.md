# 0099. Level, setup, permissions, activity (FR-830, FR-832, FR-833)

- Status: accepted
- Date: 2026-10-29
- Alias: plan 008 D8 (`specs/008-mail/plan.md`, "D8. Level, setup, permissions, activity (FR-830, FR-832, FR-833)")

## Context and problem

Decision D8 of spec 008's plan (Mail); requirements in
[requirements/mail.md](../requirements/mail.md). Requirement IDs it cites: none current.
The design it belongs to: [design/mail.md](../design/mail.md).

## Decision


- `CapabilityRegistry.mail`, levels Off, Read only, Read & write. A new capability id is
  absent from stored levels, so it starts at the default, Read & write, on first launch and on
  the update (FR-830). The registry lets a write tool replace a read tool of the same name at
  Read & write (for `mail_read`'s `mark_read`).
- Full Disk Access: already a setup step for any capability on; `Permissions.hasFullDiskAccess`
  also tries the Envelope Index. Missing: the tools say "turn on Full Disk Access" (FR-833).
- Automation for Mail (`com.apple.mail`): a setup step and Permissions-tab row while Mail is
  Read & write, like Notes and Messages (FR-833). A script refused with -1743 says plainly what
  to turn on.
- Activity: every change, draft, and send sets `ToolResult.activity` ("Claude sent an email to
  Sarah: «Lease»", "Claude moved 2 emails to Trash"), which becomes the notification and the
  activity entry (FR-832), as Notes and Messages do. `mark_read` on `mail_read` does the same.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

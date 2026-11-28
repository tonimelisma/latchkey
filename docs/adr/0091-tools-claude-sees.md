# 0091. Tools Claude sees

- Status: accepted
- Date: 2026-10-29
- Alias: plan 008 D1 (`specs/008-mail/plan.md`, "D1. Tools Claude sees")

## Context and problem

Decision D1 of spec 008's plan (Mail); requirements in
[requirements/mail.md](../requirements/mail.md). Requirement IDs it cites: none current.
The design it belongs to: [design/mail.md](../design/mail.md).

## Decision


Four tools, in the find/read/change pattern of the other capabilities, with sending a tool of
its own (FR-820, decided 2026-10-29). 27 tools in all.

| Tool | Level | readOnly | destructive | openWorld | Serves |
|---|---|---|---|---|---|
| `mail_find` | Read only | yes | no | no | FR-801, FR-802, FR-806, FR-807, FR-831 |
| `mail_read` | Read only | yes | no | no | FR-803 to FR-807 |
| `mail_change` | Read & write | no | yes | no | FR-810, FR-811, FR-821, FR-822 |
| `mail_send` | Read & write | no | no | yes | FR-820, FR-822 to FR-824 |

- `mail_find` with no arguments lists the accounts and mailboxes with their unread counts
  (FR-801). With filters it lists messages newest first, a page at a time (`offset`). With
  `text`, it searches messages' text (D4).
- `mail_read` reads one message (`id`), its conversation (`conversation: true`), or one
  attachment (`attachment`). Long text comes in pages (`offset`, `ResultLimit`).
- `mark_read` on `mail_read` (FR-805) exists only at Read & write: at that level the
  capability's `mail_read` is replaced by the same tool with the extra argument (D7). The tool
  keeps `readOnlyHint: true` at both levels, since marking read is what Mail does when a message
  is shown; a write hint would make Claude's apps ask before every read. Its description tells
  Claude to pass it when the Owner will see what the message says (Claude shows or summarises
  it) and not for its own lookups (decided 2026-10-29).
- `mail_change` actions: `mark_read`, `mark_unread`, `flag`, `unflag`, `move` (to a mailbox of
  the same account), `junk`, `not_junk`, `delete` (to the account's Trash), and `draft` (a new
  message, reply, or forward saved in the account's Drafts). `id` or `ids` for several.
- `mail_send`: a new message, a reply (`reply_to`, `reply_all`), or a forward (`forward`), with
  `text`, `attachments` (paths), and `from` (an account's name or address).
- Deadlines (`latchkey/deadline_ms`): `mail_find` 30 s (text search stops itself at 20 s),
  `mail_read` 30 s (an attachment may need downloading), `mail_change` 60 s, `mail_send` 90 s
  (attachments, then the confirmation in Sent).
- Results are text only, with ids Claude passes back (`.claude/rules/macos.md`).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

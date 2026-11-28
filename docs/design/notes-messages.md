# Notes and Messages: design

GOVERNS: `macos/App/Notes/` `macos/App/Messages/`

Spec 002's plan (migrated from `specs/002-notes-messages/plan.md`, titled "Plan 002: Notes and Messages — HOW"). What it must do:
[requirements/notes-messages.md](../requirements/notes-messages.md). Each decision Dn is an ADR, linked
where the decision stood.

Derived from `docs/requirements/notes-messages.md`; evidence in `docs/research/2026-10-21-notes-messages.md`. Every decision names the requirements it serves.

## D1. Tools Claude sees

Decision record: [ADR 0031](../adr/0031-tools-claude-sees.md).

## D2. Reading: the databases, read-only

Decision record: [ADR 0032](../adr/0032-reading-the-databases-read-only.md).

## D3. Changing: through the apps, with Apple Events

Decision record: [ADR 0033](../adr/0033-changing-through-the-apps-with-apple-events.md).

## D3a. Changing in Notes' window (2026-11-04)

Decision record: [ADR 0034](../adr/0034-changing-in-notes-window.md).

## D3b. Changing in Messages' window (2026-11-05)

Decision record: [ADR 0035](../adr/0035-changing-in-messages-window.md).

## D4. People: Contacts

Decision record: [ADR 0036](../adr/0036-people-contacts.md).

## D5. Permissions and setup

Decision record: [ADR 0037](../adr/0037-permissions-and-setup.md).

## D6. Text written by others

Decision record: [ADR 0038](../adr/0038-text-written-by-others.md).

## D7. Mac state in every answer (spec 001 FR-065)

Decision record: [ADR 0039](../adr/0039-mac-state-in-every-answer.md).

## D8. Visibility on the Mac

Decision record: [ADR 0040](../adr/0040-visibility-on-the-mac.md).

## D9. Capability levels in the app and protocol

Decision record: [ADR 0041](../adr/0041-capability-levels-in-the-app-and-protocol.md).

## Testing (Constitution VII)

- Fixture databases: small `NoteStore.sqlite` and `chat.db` files built by a test script with
  known notes and messages (including `attributedBody` blobs and compressed note bodies),
  checked in under macos/Tests/Fixtures. Decoders and queries are tested against them.
- Tool-list tests per level (SC-103); injection marking test (SC-104).
- Apple Events writes are behind a protocol so tests use a fake; one live check script exercises
  real Notes on this Mac against a dedicated test folder, run by Claude (no manual work for the maintainer).
- Relay: status line test in the MCP surface tests (FR-065).

## Constitution check

| Article | Status |
|---|---|
| I. Outbound only | Pass: no change |
| II. Fail fast | Pass: deadlines on every tool; sends and window changes confirm within 5 s or report pending; a locked Mac is answered at once (D3b) |
| III. Disabled means nonexistent | Pass: tools only for the current level (D9) |
| IV. Good macOS citizen | Pass: Apple Events and Contacts prompts; Full Disk Access by the Owner in System Settings; databases read-only; Messages' window through public Accessibility (D3b), no private frameworks (IMCore rejected) |
| V. Self-hostable | Pass: relay unchanged except the status line |
| VI. Store the minimum | Pass: relay stores nothing new; the Mac keeps its local trace only |
| VII. Test-first | Planned (fixture databases, tool-list tests) |
| VIII. Simplicity | Pass: no new projects or services |
| IX. Open source | Pass: no new dependencies planned (own protobuf and typedstream decoders) |

## Reviewed

Approved as is on 2026-10-22, including attachments from any file the Mac can read.

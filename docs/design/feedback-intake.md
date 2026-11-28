# Problem reports to the developer: design

GOVERNS: `relay/cmd/latchkey-intake/` `relay/cmd/latchkey-reports/` `relay/internal/intake/`

Spec 014's plan (migrated from `specs/014-feedback-intake/plan.md`, titled "Spec 014 plan: problem reports to the developer — HOW"). What it must do:
[requirements/feedback-intake.md](../requirements/feedback-intake.md). Each decision Dn is an ADR, linked
where the decision stood.

Built 2026-11-23. Choices and options: `docs/research/2026-11-23-feedback-intake.md`; tasks: spec 014's task list (in git history; open items are GitHub issues).

## D1. The setting (FR-1400 to FR-1403)

Decision record: [ADR 0157](../adr/0157-the-setting.md).

## D2. Asking Claude (FR-1401, FR-1405, FR-1406)

Decision record: [ADR 0158](../adr/0158-asking-claude.md).

## D3. Filing on the relay (FR-1410 to FR-1416)

Decision record: [ADR 0159](../adr/0159-filing-on-the-relay.md).

## D4. The intake (FR-1420 to FR-1425)

Decision record: [ADR 0160](../adr/0160-the-intake.md).

## D4a. Name and hosting (FR-1426)

Decision record: [ADR 0161](../adr/0161-name-and-hosting.md).

## D5. The developer's agent (FR-1430, FR-1431)

Decision record: [ADR 0162](../adr/0162-the-developers-agent.md).

## D6. Tests

Decision record: [ADR 0163](../adr/0163-tests.md).

## D7. Everything for that chat (FR-1440 to FR-1456; 2026-11-25)

Decision record: [ADR 0164](../adr/0164-everything-for-that-chat.md).

## Constitution check

- I (no inbound to the Mac): unchanged; the Mac takes no part in delivery.
- II (fail fast): `feedback` answers within 10 s at most (machines' parts, D7); delivery runs in the background with limits.
- III (off is gone): FR-1401.
- IV (never disturb): nothing on the Mac's screen except the setting itself.
- V (self-hostable): relays and the intake are both self-hostable; operators choose where
  reports go.
- VI (store the minimum): no readable report anywhere but the developer's session; the relay
  holds sealed bytes for at most 7 days; page records and the relay's log ring are memory only.
- VII (test-first): D6, written first.
- VIII (simplicity): one new small program; the standard library's HPKE.
- IX (open): no new dependencies.

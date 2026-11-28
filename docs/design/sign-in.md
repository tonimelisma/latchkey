# Signing in: design

GOVERNS: `macos/App/SignIn/`

Spec 013's plan (migrated from `specs/013-sign-in/plan.md`, titled "Plan 013: Signing in by itself — HOW"). What it must do:
[requirements/sign-in.md](../requirements/sign-in.md). Each decision Dn is an ADR, linked
where the decision stood.

Spec: `docs/requirements/sign-in.md`. Research: `docs/research/2026-11-20-sign-in.md`. Approved to build on 2026-11-20 ("do the whole
thing"). Everything is in the Mac app; the relay and the Linux program don't change (tools are
defined on the Mac and pass through the relay as they are).

## D1. Where the copies live (FR-1310, FR-1305)

Decision record: [ADR 0145](../adr/0145-where-the-copies-live.md).

## D2. Taking a file in (FR-1300, FR-1301, FR-1303)

Decision record: [ADR 0146](../adr/0146-taking-a-file-in.md).

## D3. The one-touch export (FR-1301, FR-1306)

Decision record: [ADR 0147](../adr/0147-the-one-touch-export.md).

## D4. The weekly reminder (FR-1304)

Decision record: [ADR 0148](../adr/0148-the-weekly-reminder.md).

## D5. The tools (FR-1320, FR-1326, FR-1340, FR-1371; contract `docs/design/contracts/login-tools.md`)

Decision record: [ADR 0149](../adr/0149-the-tools.md).

## D6. Typing into a page (FR-1321, FR-1328, FR-1371, FR-1372, FR-1311)

Decision record: [ADR 0150](../adr/0150-typing-into-a-page.md).

## D7. Retries and the log (FR-1324 withdrawn, FR-1327)

Decision record: [ADR 0151](../adr/0151-retries-and-the-log.md).

## D8. Where the Owner sees it (FR-1301, FR-1302, FR-1305)

Decision record: [ADR 0152](../adr/0152-where-the-owner-sees-it.md).

## D10. Latchkey's own sign-ins (FR-1350, FR-1351, FR-1353 to FR-1355, FR-1374)

Decision record: [ADR 0153](../adr/0153-latchkeys-own-sign-ins.md).

## D11. Codes texted to the Owner (FR-1360, FR-1362, FR-1363)

Decision record: [ADR 0154](../adr/0154-codes-texted-to-the-owner.md).

## D12. Codes emailed to the Owner (FR-1364 to FR-1367)

Decision record: [ADR 0155](../adr/0155-codes-emailed-to-the-owner.md).

## D9. Tests and checks

Decision record: [ADR 0156](../adr/0156-tests-and-checks.md).

## Constitution check

- I (no inbound): unchanged. II (fail fast): every step has a limit (10 s per element, 2 minutes
  for Touch ID, the tools' 30 s). III (off is gone): the capability's tools vanish at Off. IV
  (good citizen, never disturb): Passwords comes forward only because the Owner clicked; the
  reminder is a notification; filling uses no keystrokes or pointer; uninstalling removes the
  copies. V (self-hostable): nothing on the relay. VI (store the minimum): the copies stay on the
  Mac; traces never hold a secret (tool arguments and answers don't). VII (test-first): tests
  above, written first. VIII (simplicity): one item, one folder, no new program or package. IX:
  no new dependencies.

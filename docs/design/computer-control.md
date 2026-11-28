# Computer control: design

GOVERNS: `macos/App/Computer/`

Spec 006's plan (migrated from `specs/006-computer-control/plan.md`, titled "Plan 006: Computer control — HOW"). What it must do:
[requirements/computer-control.md](../requirements/computer-control.md). Each decision Dn is an ADR, linked
where the decision stood.

Derived from `docs/requirements/computer-control.md`; evidence and low-level choices in `docs/research/2026-10-22-computer-control.md`.

## D1. Tools

Decision record: [ADR 0075](../adr/0075-tools.md).

## D2. Screen state (FR-504, FR-505)

Decision record: [ADR 0076](../adr/0076-screen-state.md).

## D3. Seeing

Decision record: [ADR 0077](../adr/0077-seeing.md).

## D4. Acting

Decision record: [ADR 0078](../adr/0078-acting.md).

## D5. Permissions and setup (FR-506)

Decision record: [ADR 0079](../adr/0079-permissions-and-setup.md).

## D6. Visibility (FR-507)

Decision record: [ADR 0080](../adr/0080-visibility.md).

## D7. Safari window screenshot (FR-509)

Decision record: [ADR 0081](../adr/0081-safari-window-screenshot.md).

## D8. Forms in a named app (FR-511 to FR-514, 2026-11-03)

Decision record: [ADR 0082](../adr/0082-forms-in-a-named-app.md).

## Testing

Key-name parsing; coordinate mapping for displays of several sizes and scales; screen-state
messages; the event sequences for click, double click, right click, drag, scroll, type, key,
recorded by a fake poster; tool lists per level. Real capture is tested when this Mac has
granted the test host Screen Recording, and skipped otherwise (no pointer movement in tests).

## Constitution check

| Article | Status |
|---|---|
| I. Outbound only | Pass |
| II. Fail fast | Pass: state check first, 2 s wake wait, 20 s deadline |
| III. Disabled means nonexistent | Pass |
| IV. Good macOS citizen | Pass: Screen Recording and Accessibility granted by the Owner; never unlocks |
| V. Self-hostable | Pass |
| VI. Store the minimum | Pass: screenshots are not kept |
| VII. Test-first | Planned |
| VIII. Simplicity | Pass: ScreenCaptureKit, Quartz events, Accessibility API |
| IX. Open source | Pass |

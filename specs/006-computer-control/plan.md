# Plan 006: Computer control — HOW

Derived from `spec.md`; evidence and low-level choices in `research.md`.

## D1. Tools

Claude sees consolidated tools (Toni, 2026-10-23: 15 tools in all, from 45): the table below. The operations listed after it are their internals, each reached by an `action` or by which arguments are given.

| Tool | Level | readOnly | destructive | Operations behind it |
|---|---|---|---|---|
| `computer_look` (show: screenshot, ui, apps; display?) | Read only | yes | no | screenshot, front window, apps |
| `computer_act` (action: click, move, drag, scroll, type, key, open_app; …) | Read & write | no | yes | the matching action |

Operations:

| Tool | Level | readOnly | destructive | Serves |
|---|---|---|---|---|
| `computer_screenshot` (display?) | Read only | yes | no | FR-501, FR-503 |
| `computer_ui` | Read only | yes | no | FR-501 |
| `computer_apps` | Read only | yes | no | FR-501 |
| `computer_click` (x, y, button?, count?) | Read & write | no | yes | FR-502 |
| `computer_move` (x, y) | Read & write | no | no | FR-502 |
| `computer_drag` (from_x, from_y, to_x, to_y) | Read & write | no | yes | FR-502 |
| `computer_scroll` (x, y, direction, amount?) | Read & write | no | no | FR-502 |
| `computer_type` (text) | Read & write | no | yes | FR-502 |
| `computer_key` (keys) | Read & write | no | yes | FR-502 |
| `computer_open_app` (name) | Read & write | no | no | FR-502 |
| `browser_screenshot` | Browser Read only | yes | no | FR-509 |

Actions answer with a new screenshot taken 0.5 s later, so Claude sees the effect without a
second call. Deadline 20 s.

## D2. Screen state (FR-504, FR-505)

Before every tool: no active display → "no screen" (lid closed without a monitor); locked
(`CGSSessionScreenIsLocked`) → "locked"; display asleep → "asleep", left asleep (until
2026-11-02 it was woken with a user-activity assertion, which reset the idle time, so Claude's
looks could keep an idle Mac from locking; Toni: never get around the idle lock). Each reason is a plain sentence
that also says files, shell, Notes, Messages, and the browser still work.

## D3. Seeing

ScreenCaptureKit captures a display at a size whose longest side is at most 1,568 pixels; the
answer gives the image and its size. Each display's scale (screen points per image pixel) is
fixed by that rule, so coordinates mean the same with or without a fresh screenshot (FR-503).
`computer_ui` reads the front app's focused window through the Accessibility API (role, label,
value, position in screenshot pixels), at most 300 elements, 15 levels deep. The front app
reports its own frames: one that isn't a point and size, or whose position is NaN, infinite, or
far off any screen, is listed with "no position" instead of crashing the conversion (security
scan, 2026-10-24).

## D4. Acting

Quartz events through a small poster interface (a fake in tests): mouse move, down/up with the
click count, right button, drag in 10 steps, scroll in lines, Unicode text in chunks, key
combinations by name (`cmd+shift+4`). Points are screenshot pixels mapped to the display's
global coordinates. Opening apps uses NSWorkspace by name.

## D5. Permissions and setup (FR-506)

Two setup steps while Computer control isn't Off: Screen Recording (`CGRequestScreenCaptureAccess`,
then System Settings → Screen & System Audio Recording) and Accessibility
(`AXIsProcessTrustedWithOptions` with the prompt, then System Settings → Accessibility). The
window notices both. Tools explain a missing one.

## D6. Visibility (FR-507)

Every action returns an activity; the first after 5 minutes idle also posts the notification
"Claude is using your screen".

## D7. Safari window screenshot (FR-509)

ScreenCaptureKit finds Safari's window whose title is the title of Claude's current tab, and
captures it at the same size limit.

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

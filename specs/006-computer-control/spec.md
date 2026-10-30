# Spec 006: Computer control — WHAT and WHY

Status: Built without a review stop (Toni, 2026-10-22); reviewed and approved by Toni, 2026-10-29.
Scope: Claude sees the Mac's screen and uses its mouse and keyboard, in any app, while the
screen is on and unlocked. Also a screenshot of Claude's Safari window (spec 005).
Out of scope: unlocking the Mac or typing passwords for the Owner.

## Problem

Some apps have no other way in: no database, no scripting, no web version. With the screen,
Claude can use them the way the Owner would.

## User stories

### US1 (P1): Look at my screen
1. Given Computer control is Read only or more and the Mac is unlocked, when I ask "what's on
   my screen?", then Claude sees a screenshot and the text of the front window.

### US2 (P1): Do something in an app
1. Given Read & write, when I ask Claude to change a setting in an app with no other access,
   then it clicks and types like a person would.

### US3 (P1): Know why it can't
1. Given the Mac is locked, the display is off, or the lid is closed without a monitor, then
   Claude says so plainly, and that the other capabilities still work (Toni accepted this
   limit, 2026-10-22).

## Requirements

- **FR-501** While Computer control is Read only or Read & write, Claude shall be able to take
  a screenshot of any display, read the front window's buttons, fields, and text, and list the
  open apps.
- **FR-502** While Read & write, Claude shall be able to move the pointer, click (left, right,
  double), drag, scroll, type text, press keys and shortcuts, and open apps.
- **FR-503** Coordinates shall refer to the pixels of the screenshot Claude saw.
- **FR-504** When the screen is locked, the display is asleep and can't be woken, or there is
  no display, the tools shall answer with the reason instead of acting.
- **FR-505** Latchkey shall never type the Owner's password or unlock the Mac.
- **FR-506** When Screen Recording or Accessibility permission is missing, the setup window
  shall show the step and the tools shall explain what to turn on.
- **FR-507** The first action after five minutes without one shall show a notification that
  Claude is using the screen; every action appears in the menu's activity.
- **FR-508** Computer control shall have the levels Off, Read only, Read & write, and start at
  Read & write (Toni, 2026-10-22).
- **FR-509** While Browser is on, Claude shall be able to take a screenshot of its Safari window
  (spec 005), under the same screen conditions.

## Success criteria

- **SC-501** With the Mac unlocked, Claude describes what's on screen from a phone.
- **SC-502** With the Mac locked, every screen tool answers with "the Mac is locked" within 2 s.
- **SC-503** With Computer control Read only, no tool that clicks or types appears (test suite).

## Edge cases

- Several displays, of different sizes and scales; the display arrangement changes.
- The Owner using the Mac at the same time.
- Secure text fields (passwords) block synthetic typing; Claude is told typing didn't arrive.

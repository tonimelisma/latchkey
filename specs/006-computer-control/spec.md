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
- **FR-504** When the screen is locked, the display is asleep, or there is no display, the
  tools shall answer with the reason instead of acting. A sleeping display is not woken (Toni,
  2026-11-02: Latchkey never gets around the Mac's idle lock, lid open or closed).
- **FR-505** Latchkey shall never type the Owner's password or unlock the Mac.
- **FR-506** When Screen Recording or Accessibility permission is missing, the setup window
  shall show the step and the tools shall explain what to turn on.
- **FR-507** The first action after five minutes without one shall show a notification that
  Claude is using the screen; every action appears in the menu's activity.
- **FR-508** Computer control shall have the levels Off, Read only, Read & write, and start at
  Read & write (Toni, 2026-10-22).
- **FR-509** While Browser is on, Claude shall be able to take a screenshot of its Safari window
  (spec 005), under the same screen conditions.
- **FR-510** Claude shall be able to name one app and, without bringing it forward or moving the
  pointer, see a picture of just its front window (also while other windows cover it), list its
  buttons, fields, and text with references, press one, type into it, and press keys in it;
  clicks, moves, drags, and scrolls at a point still use the pointer (Toni, 2026-11-02:
  "Background first").
- **FR-511** When Claude types into an element of a named app, the keys shall be sent only once
  that app's keyboard focus is on the element or inside it; otherwise nothing shall be typed and
  the answer shall say where the focus is. The answer shall give the element's value after
  typing, and when Claude types or presses keys without an element, where the focus was (bug
  report 2026-11-03: keys meant for a web page's State dropdown chose a payment method).
- **FR-512** A list of an app's window shall show each element once and leave out text that only
  repeats a label next to it; it shall show 300 elements at a time and say when more follow;
  Claude shall be able to continue after an element, list only what is inside one, or only what
  has a word, all from the same look so references stay the same; and it shall say when the
  window has more than one look reads. The front window's list shall say when it stops (bug
  report 2026-11-03: a form's Submit button was past a silent cut at 300; Toni, 2026-11-03:
  "Continue, narrow, dedupe").
- **FR-513** Claude shall be able to choose an option in a named app's dropdown by the option's
  name, in the background, without a menu opening over the Owner's screen; the answer shall say
  the dropdown's value afterwards, or that no such option showed (Toni, 2026-11-03: "Yes, a
  choose action").
- **FR-514** After pressing, typing, or choosing in a named app, the answer shall name every other
  field, checkbox, or dropdown from the last look whose value changed (bug report 2026-11-03: a
  press on one dropdown seemed to check two checkboxes elsewhere).

## Success criteria

- **SC-501** With the Mac unlocked, Claude describes what's on screen from a phone.
- **SC-502** With the Mac locked, every screen tool answers with "the Mac is locked" within 2 s.
- **SC-503** With Computer control Read only, no tool that clicks or types appears (test suite).

## Edge cases

- Several displays, of different sizes and scales; the display arrangement changes.
- The Owner using the Mac at the same time.
- Secure text fields (passwords) block synthetic typing; Claude is told typing didn't arrive.

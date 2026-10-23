# Spec 005: Browser control — WHAT and WHY

Status: Approved to build without a review stop (Toni, 2026-10-22); Toni reviews at the end.
Scope: Claude uses the Owner's Safari on the Mac, with the Owner's logins: opens pages, reads
them, follows links, fills in and submits forms.
Out of scope: other browsers (Toni chose Safari, 2026-10-22); clicks that need a real mouse
(computer control, spec 006).

## Problem

Many sites have no API and no connector, and the Owner is signed in to them on the Mac. From a
phone, Claude can't check a reservation in the Owner's account or fill in a form there.

## User stories

### US1 (P1): Read sites I'm signed in to
1. Given Browser is Read only or more, when I ask "what's my next delivery on my grocery site?",
   then Claude opens the site in Safari on my Mac, signed in as me, and reads the answer.

### US2 (P1): Act on sites
1. Given Browser is Read & write, when I ask Claude to fill in and send a form, then it does.

### US3 (P1): Stay out of my way
1. Claude works in a Safari window of its own and never touches my other windows and tabs.

## Requirements

- **FR-401** While Browser is Read only or Read & write, Claude shall be able to open a web
  page, read its text, links, buttons, and fields, list and switch its tabs, and go back.
- **FR-402** While Browser is Read & write, Claude shall be able to click links and buttons,
  type into fields, choose options, submit forms, and run its own script in the page.
- **FR-403** Claude shall use the Owner's Safari with the Owner's logins and saved sessions
  (Toni, 2026-10-22), in a window of its own; it shall not read or change the Owner's other
  windows and tabs.
- **FR-404** Page content shall be marked as written by the website, not instructions.
- **FR-405** Results shall stay within Claude's result size, with a way to read on.
- **FR-406** When Safari's "Allow JavaScript from Apple Events" or the Automation permission is
  missing, the setup window shall show the step, and tools shall explain what to turn on.
- **FR-407** Browser shall have the levels Off, Read only, Read & write, and start at Read &
  write (Toni, 2026-10-22).
- **FR-408** Each click, typing, and script Claude does shall appear in the menu's activity.

## Success criteria

- **SC-401** From the phone, Claude reads a page of a site the Owner is signed in to on the Mac.
- **SC-402** With Browser Read only, no tool that clicks or types appears (test suite).

## Edge cases

- The Owner closes Claude's window: the next request opens a new one.
- Pages that keep loading or change constantly; very long pages; pages in frames.
- Sites that ignore script-driven clicks (rare): Claude is told nothing changed and can use
  computer control when the screen is on.
- Safari not running: Latchkey starts it.

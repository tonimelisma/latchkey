# 0137. The Owner's WhatsApp Web tab in Safari

- Status: accepted
- Date: 2026-11-04
- Alias: plan 012 D1 (`specs/012-whatsapp/plan.md`, "D1. The Owner's WhatsApp Web tab in Safari")

## Context and problem

Decision D1 of spec 012's plan (WhatsApp); requirements in
[requirements/whatsapp.md](../requirements/whatsapp.md). Requirement IDs it cites: FR-1206, FR-1222.
The design it belongs to: [design/whatsapp.md](../design/whatsapp.md).

## Decision


Serves FR-1206, FR-1208, FR-1214, FR-1215, FR-1222.

- `SafariWhatsApp` finds the first tab in any Safari window whose address starts with
  `https://web.whatsapp.com` and runs JavaScript in it with Safari's `do JavaScript` (AppleScript,
  through `osascript` like every Safari script, spec 005). It never selects, reloads, navigates,
  or closes the tab, and never activates Safari (FR-1208).
- Safari's `do JavaScript` returns at once and can't wait for a page's promise. Each call is one
  script that injects the bridge (D2) when the page lacks it or has an older version, starts the
  bridge function with its answer kept in `window.__lkr[<random id>]`, then asks for that answer
  every 0.2 s until it comes or the call's time is up. Options weighed: one `do JavaScript` per
  poll from Swift (an `osascript` start each, about 0.1 s), or the polling inside one AppleScript
  (one process). Chosen: inside one AppleScript.
- The arguments go to the page as JSON written into the script text (JSON is JavaScript), and the
  function name is one of the bridge's fixed names; the user's text never becomes code.
- Needs Safari's Develop → Allow JavaScript from Apple Events (as the browser tools do, spec 005)
  and Automation for Safari. When either is missing, or no WhatsApp tab is open, or Safari doesn't
  answer (seen 2026-11-01 with the Mac locked), the tab counts as unusable with that reason.
- No watchdog: the tab is the Owner's. A tab stuck connecting is reported, not reloaded.
- Several WhatsApp tabs: the first one found (window order, then tab order).
- No WhatsApp tab (FR-1208): Latchkey opens `https://web.whatsapp.com/` at the end of Safari's
  front window without selecting it (a new window when there is none), then waits up to 25 s for
  it to connect with Safari's own login (the same linked device as the Owner's tab; nothing new
  is linked). Options weighed: answer "open WhatsApp Web" (nothing done unasked, but sending from
  away fails whenever the tab was closed), or open it (works from anywhere; a tab appears).
  Chosen by decided: open it.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/WhatsAppToolsTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

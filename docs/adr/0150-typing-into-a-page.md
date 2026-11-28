# 0150. Typing into a page (FR-1321, FR-1328, FR-1371, FR-1372, FR-1311)

- Status: accepted
- Date: 2026-11-22
- Alias: plan 013 D6 (`specs/013-sign-in/plan.md`, "D6. Typing into a page (FR-1321, FR-1328, FR-1371, FR-1372, FR-1311)")

## Context and problem

Decision D6 of spec 013's plan (Signing in); requirements in
[requirements/sign-in.md](../requirements/sign-in.md). Requirement IDs it cites: FR-1321, FR-1328, FR-1371, FR-1372, FR-1311, FR-455, FR-1325.
The design it belongs to: [design/sign-in.md](../design/sign-in.md).

## Decision


`logins_fill` takes `page`, `field` (a reference from the page reading), `fill` (`user`,
`password`, `code`), `press` (needed for a password or a code), `user`, `code`,
`no_email_access`. It works only in Claude's own pages: Latchkey's own browser, or a Safari tab of
Claude's (spec 005 FR-455); never the Owner's tabs. One call:

1. Read the page's address from the browser (`signInHere`, the browser's own record); pick the
   sign-ins whose site fills there (`SiteMatch`, `fillHost`). None: say so (FR-1325). Several
   user names and none given: list them.
2. Find the value: the user name, the password, or a code (D11, D12, the generator from
   Passwords once per step, or the one Claude passed). No code yet: say so at once, type nothing.
3. Run `PageScripts.fillField` in the page's main frame only: it checks the page is https on that
   host itself, finds the field by its reference, refuses a field of the wrong kind (FR-1372),
   types key by key (key events with codes, beforeinput, the caret, input), and for a code from a
   one-character box (or the first of a row of alike fields) types one character a box, pasting
   whole into the first when the boxes won't take it so. It answers whether the field holds it.
4. Press the button Claude named with the browsers' own click (which waits for the page to
   settle), then run `clearSignIn`, which empties every password field and every field Latchkey
   typed into that is still there: a password or a code never stays in the page for a script of
   Claude's to read. A user name may be typed alone.
5. Answer what was typed where and what was pressed, then the page as browser_read shows it. No
   judgement of the page, ever.

Secrets reach the page only inside the script: in Latchkey's own browser through WebKit directly,
in its own content world; in Safari always through the 0600 script file in a 0700 folder,
removed right after, never as an `osascript` argument (which other programs can see).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/BrowserTabTests.swift`
- `macos/Tests/SignInDataTests.swift`
- `macos/Tests/SignInFillTests.swift`
- `macos/Tests/SignInRoutingTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

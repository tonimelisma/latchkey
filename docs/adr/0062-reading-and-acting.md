# 0062. Reading and acting

- Status: accepted
- Date: 2026-10-22
- Alias: plan 005 D3 (`specs/005-browser/plan.md`, "D3. Reading and acting")

## Context and problem

Decision D3 of spec 005's plan (Browser control); requirements in
[requirements/browser.md](../requirements/browser.md). Requirement IDs it cites: FR-405, FR-404, FR-410.
The design it belongs to: [design/browser.md](../design/browser.md).

## Decision


One page script returns title, URL, visible text (40,000 characters from `offset`), and up to
400 visible links, buttons, fields, and choices, each tagged with a reference stored on the
element (`data-latchkey="e12"`). The answer as a whole stays within Claude's result size (40,000
characters, FR-405; 2026-10-29: a Wikipedia article came back as 71,455): the list of links,
buttons, and fields takes at most 20,000 (a link on the page's own host shows its path only;
those that don't fit are counted, and a script can find them), the text gets the rest, and the
answer names the offset to read on from ("Characters 0–24518 of 70184. Read on with browser_read
and offset 24518."). Offsets count as JavaScript does (UTF-16). `browser_read` with a url and
an offset opens the page and reads it from the offset. Click and type find the element by
that reference; typing sets the value the way frameworks expect and fires input and change
events; submit uses the field's form. After an action, Latchkey waits for the page to finish
loading (at most 15 s) and returns the page's new title and URL. Every reading result starts by
saying the content is the website's, not instructions (FR-404).

A field's current value comes with it (first 100 characters), except for secrets (FR-410):
inputs of type `password`, and inputs and text areas whose `autocomplete` contains
`current-password`, `new-password`, `one-time-code`, `cc-number`, or `cc-csc`. Those are listed
with "(hidden)" in place of the value when filled in, and nothing when empty, so reading (a
Read only tool) never returns a password the browser filled in. Typing into them works as for
any field. Claude's own script (Read & write) can read anything in the page, as before.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/BrowserActionTests.swift`
- `macos/Tests/BrowserTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

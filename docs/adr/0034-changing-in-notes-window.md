# 0034. Changing in Notes' window (2026-11-04)

- Status: accepted
- Date: 2026-11-04
- Alias: plan 002 D3a (`specs/002-notes-messages/plan.md`, "D3a. Changing in Notes' window (2026-11-04)")

## Context and problem

Decision D3a of spec 002's plan (Notes and Messages); requirements in
[requirements/notes-messages.md](../requirements/notes-messages.md). Requirement IDs it cites: FR-106.
The design it belongs to: [design/notes-messages.md](../design/notes-messages.md).

## Decision


Serves FR-106, FR-155 to FR-159; research "Notes' window".
- Route: a note with nothing AppleScript would lose (no checklists, links, mentions, tags,
  images, tables) is changed with AppleScript as in D3, which keeps headings and lists. Any
  other note is changed in Notes' window. Text with checklist items goes in as ☐/☑ lines either
  way, then each of those lines, and only those, becomes a real checklist item in the window.
- The window: AppleScript `show note id …` puts the note in Notes' main window without making
  Notes the front app (and answers the note shown before, shown again at the end). The note's
  editor is the `AXTextArea` whose `AXIdentifier` is `Note[id=<the note's id>]`, so Latchkey
  knows it has the right note; it waits up to 5 s for it.
- Text: the editor's `AXSelectedTextRange` is set to the passage and `AXSelectedText` to the
  new text, which Notes treats like typing there: checklists, links, and images elsewhere stay.
  Images show in the editor's text as U+FFFC. Headings, bullets, and numbered lines written into
  such a note are plain lines (`• ` for bullets): the format panel's buttons don't answer
  Accessibility presses in the background (tried 2026-11-04).
- Checklists (changed 2026-11-06): each written line is set with Notes' Format → Checklist and
  ticked with Format → Mark as Checked, in one moment with Notes in front (about a second; the
  app that was in front gets it back). Before each command the editor gets the keyboard focus and
  the caret; then every line's state is read back and any difference is answered, not hidden.
  Checklist lines are written as plain paragraphs. Superseded:
- Checklists: the toolbar's Checklist button (found by the name of the Format menu item with
  ⇧⌘L, so it works in any language) is pressed for each ☐/☑ line after the ☐/☑ is removed; its
  value says whether the line already is one. Pressing it works in the background.
- Ticking: Format → Mark as Checked (⇧⌘U) is disabled while Notes isn't the front app, so for
  ticking Notes is made active, the caret put in each item, the menu item pressed, and the app
  that was in front activated again (about 1.3 s, tried 2026-11-04). Whether an item is ticked
  comes from the database (D2).
- One change at a time (a queue), since the window is shared. The answer comes once the
  database shows the change (up to 5 s), else says Notes hasn't saved it yet.
- While the Mac is locked Notes' window has no note editor (tried 2026-11-04), so nothing is
  tried and the answer says so at once; otherwise the wait for the editor ends after 5 s.
- When the window can't be used, the change isn't started (FR-158); for create and for plain
  notes the AppleScript part is already done, so its ☐/☑ lines stay as they are and the answer
  says so.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/NotesWriteTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

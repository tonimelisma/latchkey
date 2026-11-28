# 0082. Forms in a named app (FR-511 to FR-514, 2026-11-03)

- Status: accepted
- Date: 2026-11-03
- Alias: plan 006 D8 (`specs/006-computer-control/plan.md`, "D8. Forms in a named app (FR-511 to FR-514, 2026-11-03)")

## Context and problem

Decision D8 of spec 006's plan (Computer control); requirements in
[requirements/computer-control.md](../requirements/computer-control.md). Requirement IDs it cites: FR-511, FR-514, FR-512, FR-513.
The design it belongs to: [design/computer-control.md](../design/computer-control.md).

## Decision


Checked on a WebKit test page in a window kept behind (FormLab, the same engine as Safari),
driven through Accessibility as Latchkey does:

- Focus (FR-511): setting `AXFocused` answers success on a page's text and on a button in a
  frame while the focus stays where it was (on the Country dropdown in the check), so success
  means nothing. After asking, Latchkey reads the app's `AXFocusedUIElement` and accepts it
  when it is the element or inside it (its parents up to 40 levels), asks once more after
  400 ms, and otherwise types nothing and names what has the focus. As Mail's own check
  (spec 008, `focused(in:)`). The value is read back after the settle; without an element the
  answer names what had the focus.
- Listing (FR-512): a table's cells are its rows' children, its columns' children, and its
  header's, so each was listed two or three times; the walk skips an element it has seen
  (`CFEqual`). It reads up to 2000 elements (20,000 looked at, 40 levels), keeps that look per
  app, and shows 300 at a time: `after`, `within` (by the nearest listed parent), and `match`
  read the kept look, so references never shift between parts (a fresh look would renumber
  after any change on the page, and a reference Claude holds would point at another element).
  A static text is left out when it repeats the label of the next control, the value or label of
  the element it is in, or the text just before it. Options weighed: paging by fresh looks
  (renumbers), dropping zero-size elements (would hide real ones on some pages; not done).
- Choose (FR-513): a native menu (`AXPopUpButton`) has no options until opened, and opening it
  shows a menu over the Owner's screen; with the focus on it, typing the option's name selects
  it without opening (the page got its change event in the check), and the value is compared
  with the option. A web page's own dropdown is pressed (`AXPress`), the window read again, and
  the option, a text, menu item, cell, row, or button with that name, preferably inside a list,
  menu, or table, pressed; when none shows, the name is typed into it (a list that shows what
  was typed) and looked for again.
- Other changes (FR-514): before and after an action, the values of the last look's fields,
  checkboxes, radio buttons, and dropdowns are read; any change other than the acted-on element
  is named (10 at most). The pressed combobox in the check changed nothing else, so the
  report's two checked boxes stay unexplained; this is how Claude would see it.
- A first look (2026-11-03, live): a WebKit app just started lists only its window and title
  bar buttons until its tree is asked for once, and Chrome and Electron apps build theirs only
  with `AXManualAccessibility` set on the app. A look that finds only those sets it and looks
  again after 500 ms (awaited, never a blocked thread).
- Focus in an app behind others (2026-11-03, live): the app's `AXFocusedUIElement` reads as
  nothing, while each element's own `AXFocused` flag stays right; the check falls back to the
  flag on the element or inside it, and names the last look's element whose flag is set.
- Keys go one event per 16 characters with the first character's key code (the check's page saw
  code 67 for "C"), not "a" for each, as the report feared.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/ComputerFormTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

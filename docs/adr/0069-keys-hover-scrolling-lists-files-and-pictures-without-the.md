# 0069. Keys, hover, scrolling, lists, files, and pictures without the screen (2026-11-05)

- Status: accepted
- Date: 2026-11-05
- Alias: plan 005 D10 (`specs/005-browser/plan.md`, "D10. Keys, hover, scrolling, lists, files, and pictures without the screen (2026-11-05)")

## Context and problem

Decision D10 of spec 005's plan (Browser control); requirements in
[requirements/browser.md](../requirements/browser.md). Requirement IDs it cites: FR-433, FR-440, FR-434, FR-435, FR-436, FR-437, FR-438, FR-439, FR-423.
The design it belongs to: [design/browser.md](../design/browser.md).

## Decision


Serves FR-433 to FR-440 (decided: "all the safari stuff"). Options, tried against real Safari,
in `docs/research/2026-10-22-browser.md` ("Keys, hover, scrolling, files, and pictures"). Every action is a page script
(`PageActions.swift`), run like a click: through the survey, the guard, and the mark of D6 and
D8, so it works in Claude's background tab and in the Owner's tab Claude works in, never brings
anything forward, and runs the same in Latchkey's own browser while the Mac is locked (D7).
Values go into the page as one JSON text through `literal(...)` only. Each answers "ok", a tab,
and JSON of what it did; "missing", "nooption", "notfile", "single", "nolink" become the errors
Claude reads. Keys, a choice, and attaching count as Claude's own action that may navigate
(a key that sends a form, a list that loads a page), with the click's note rules and settle
wait; hover and scroll don't.

- **Keys** (FR-433): keydown, keypress for characters, and keyup on the focused element (the
  field `ref` names is focused first), with key, code, keyCode, and modifiers as a keyboard
  sends them. Where the page doesn't take the key itself (`preventDefault`), the script does
  what the browser would: a character or Backspace edits the field (beforeinput and input
  events, at the cursor), Command or Control-A selects all, Return sends a field's form
  (`requestSubmit`) or clicks a button or link, Space clicks a button, Tab and Shift-Tab move
  the focus through the page's focusable elements, arrows and Home/End change a list's choice,
  and keys that scroll scroll the nearest part that scrolls. Escape and shortcuts reach the
  page's own handlers. The answer lists what each key did. Names: Enter/Return, Escape/Esc, Tab,
  Backspace, Delete, Space, the arrows (also up/down/left/right), Home, End, PageUp, PageDown,
  single characters, and `cmd+`, `ctrl+`, `alt+`/`option+`, `shift+` before them; at most 50
  keys per call, given as a list or as one text split at spaces.
- **Hover** (FR-434): pointerover, pointerenter (on the element and its parents),
  mouseover, mouseenter, pointermove, mousemove at the element's middle (scrolled into view).
  The answer counts the elements that became visible.
- **Scrolling** (FR-435): a wheel event first (maps and carousels scroll themselves); unless the
  page took it, the nearest part that scrolls (from `ref`, else the page) moves by `amount`
  pixels or 90% of what shows, or to the top or bottom. The answer gives the position, the most
  it can be, and whether anything moved. Reading a page lists up to 20 parts that scroll on
  their own (`scrollable`).
- **Lists** (FR-436): a `select` gets the options whose text, label, or value match (several in
  a `multiple` one), then input and change; a list the page builds (role combobox, listbox,
  menu, or a popup button) is opened with a click and the matching item (role option, menu item)
  gets pointer and mouse events and a click. An option that isn't there is refused with up to
  50 that are (website text). Reading a page also lists combo boxes, list boxes, menus,
  switches, radios, and elements with `aria-haspopup`.
- **Attaching files** (FR-437): `BrowserDownloads.attachments` reads each path (a `~` path too;
  folders refused; at most 30 MB together), the type from the extension. The page script
  builds `File`s from the bytes (base64) into a `DataTransfer` and sets the file field's
  `files`, then input and change, as a picked file; a field that takes one file refuses more; a
  label or wrapper with one file field inside uses it; any other element gets dragenter,
  dragover, and drop with the files (refused when the page takes neither). Reading a page lists
  file fields also when hidden (labelled "(hidden file field)"). A script longer than 200 KB
  (most attachments) can't go as an `osascript` argument (macOS allows about 1 MB for all of
  them): it goes in a file only the Owner's account can read (`0600`, in a `0700` folder of the
  temporary folder), which the AppleScript itself reads (`Script.readCode`), removed right after.
- **Saving files** (FR-438): the page fetches the file (`fetch`, the page's cookies and session;
  a file the page made itself, `blob:` and `data:`, too): the link `ref` names, `url`, or the
  page's own address; the result waits in the page under a hidden property and is taken by a
  second script, asked every 0.15 s for up to 20 s, as base64 (at most 50 MB). When the page may
  not fetch it (another site's file without its permission), Latchkey fetches the address
  itself (`URLSession`, ephemeral, Safari's user agent and Safari's cookies, at most 500 MB).
  The name is the server's (`Content-Disposition`, RFC 6266 `filename*` first), else the link's
  `download` name, else the address's last part, else "download", with the extension of the
  type when it has none; cleaned of folders, control characters, and a leading dot, at most 200
  characters. The file is created new in `~/Downloads` ("name 2.pdf" when taken, never over
  another file) and marked `com.apple.quarantine`, as Safari's downloads are. The answer gives
  the path and says to read it with `files_read`. A site's error status (400 and up) saves
  nothing.
- **Pictures without the screen** (FR-439): `browser_screenshot` captures the screen as before
  when it can; when it can't (no screen permission, `ScreenCheck` says locked, asleep, or no
  screen) or the Owner can see the window (FR-423), one page script copies the page as it is
  (its markup with what fields hold, checked and chosen options, canvases as pictures, pictures'
  current sources; password fields as dots; the page's scripts removed and forbidden by a
  `script-src 'none'` policy; at most 8 MB), and Latchkey's own browser (D7, with scripts off,
  the window's size, Safari's cookies so pictures load) draws it at the page's scroll position
  (`takeSnapshot`). A page Safari lets no script into is loaded fresh from its address instead,
  as before. The answer says the picture is drawn, not captured. While the Mac is locked and
  Claude works in its own page, Latchkey's own browser draws that page, as before.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/BrowserActionTests.swift`
- `macos/Tests/BrowserOwnerTabTests.swift`
- `macos/Tests/BrowserSavedFilesTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

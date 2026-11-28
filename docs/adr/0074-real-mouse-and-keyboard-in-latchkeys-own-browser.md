# 0074. Real mouse and keyboard in Latchkey's own browser (FR-478 to FR-489, 2026-11-25)

- Status: accepted
- Date: 2026-11-25
- Alias: plan 005 D15 (`specs/005-browser/plan.md`, "D15. Real mouse and keyboard in Latchkey's own browser (FR-478 to FR-489, 2026-11-25)")

## Context and problem

Decision D15 of spec 005's plan (Browser control); requirements in
[requirements/browser.md](../requirements/browser.md). Requirement IDs it cites: FR-478, FR-489, FR-486, FR-1377, FR-480, FR-483, FR-479, FR-484, FR-485, FR-481, FR-482, FR-1372, FR-465, FR-487.
The design it belongs to: [design/browser.md](../design/browser.md).

## Decision


Serves FR-478 to FR-486 and spec 013 FR-1377; options and why in research.md, "Real mouse and
keyboard (2026-11-25)".

- **Events.** `RealInput` (`macos/App/Browser/RealInput.swift`) makes AppKit events
  (`NSEvent.mouseEvent`, `NSEvent.keyEvent`) for the never-shown window (`LockedBrowser.holder`)
  and hands them straight to the page's `WKWebView` (`mouseMoved`, `mouseDown`, `mouseUp`,
  `keyDown`, `keyUp`, `performKeyEquivalent`, `insertText`), as WebKit's own tests do. Nothing
  goes through the window server, `NSApp.sendEvent` or `CGEvent` posting, so no other view, app
  or event monitor sees them (FR-478, FR-1377; Constitution IV). A point on the page is turned
  into the window's with the view's own `convert(_:to:)`. Characters map to a US keyboard's
  key codes and Shift; others go as `insertText` (FR-480). Key characters are never logged.
- **Focus (FR-483).** The holder is a window class of Latchkey's own (`HolderWindow`) that says
  it is the key window only while `active` is set; the view is its first responder from the
  start. `LockedBrowser.acting(_:)` sets it for the length of one call and tells WebKit with the
  window's became-key and resigned-key notifications for that window only. The window never
  becomes key for AppKit, never comes forward, and the app is never activated.
- **Where and what (FR-478, FR-479, FR-484).** A script in a world of Latchkey's own
  (`RealInput.world`, which the page's scripts can't change) finds the element by its
  reference, refuses lists, colour, date and time fields, scrolls it into view
  (`scrollIntoView`, block and inline "nearest", or centred when it doesn't fit), and answers the
  middle of its first box that shows, in the top page's coordinates (frames of the same site
  added in), and what `elementFromPoint` finds there: the element, something inside it, or
  another element (then named in the answer).
- **Waiting (FR-485).** A user script in the same world, in every frame, posts each trusted
  pointer-up, mouse-up, key-up and input event to a message handler only that world has
  (`InputSignal`), with the element each character went into and whether the page took the
  key. Keys go one after the other (WebKit keeps them in order); before a step that isn't a
  key (text, a script, a click) and at the end, Latchkey waits until the page took every key
  sent, at most 10 s (`RealInput.stepLimit`, `settle`), looking only at what it was told: asking the page after every key
  kept a busy Mac busier (GitHub's runner, 2026-11-25). A page that never gets the event (a
  disabled button takes none) costs that wait once and the answer goes on. Nothing is decided
  from the page's own scripts' output.
- **Typing (FR-480).** Click the field; Select All (`selectAll(_:)`, the Edit menu's action)
  when the field holds something; one key per character, waiting per key; submit is Enter.
- **Keys (FR-481).** A field Claude names is clicked; a button or link gets the focus as Tab
  gives it (`focus()` in Latchkey's world; the keys after it are real). Before each key the world
  says what has the focus: a one-line list there refuses arrows, space and Enter (FR-484).
  Cmd+A: the key events, then `selectAll(_:)` unless the page cancelled the keydown (the world's
  listener notes `defaultPrevented`). Cmd+C, X and V are refused.
- **Hover (FR-482).** Scroll into view, then two pointer moves (just outside, then the middle),
  each handed to the owner of the view's tracking area for pointer moves, as macOS hands it: a
  WKWebView drops a move handed to the view itself (WebKit's `WKMouseTrackingObserver` takes
  them, so as not to count one twice; found 2026-11-25 with the hover diagnostic on GitHub's
  runner). The answer counts what became visible, as before.
- **Sign-in (spec 013 FR-1377).** `LockedBrowser.fillReal` runs the sign-in checks of
  `fillField` unchanged (`SignInScripts.fillPlan`: the site, the field kind, the code boxes) in
  the sign-in world, which answers the fields to type into, in order. For each: a real click,
  a check that it has the focus, Select All and Backspace if it holds something, then per
  character a check that the focus is still on it (for a code typed into one field, the page's
  next code box after it may take over, FR-1372) and the key. A focus anywhere else stops the
  typing; `clearSignIn` empties what was typed. The fields typed are kept in the world's
  `__latchkeyFilled` as before. The paste fallback for code boxes stays a script (pasting for
  real would put the code on the Owner's clipboard). The press is `click` (D15 above).
- **Gestures (FR-489, security review 2026-11-25).** A user script in the page's world, before
  its own, in every frame, makes `navigator.clipboard` refuse and `execCommand` copy, cut and
  paste do nothing (`RealInput.noClipboard`); `setAllMediaPlaybackSuspended(true)` before each
  action; `NSPasteboard.general.changeCount` compared around it. `RealInput.allowedCommand`
  lists the Command shortcuts pressed. Every script a real action waits on is bounded
  (`LockedBrowser.bounded`, 10 s; logins_fill's typing 20 s in all), and each character is
  checked afterwards to have gone into the field, in a frame of the saved site as WebKit names
  the frame (`RealInput.lastTarget`): the very node, marked in Latchkey's input world
  (`markField`), told afresh for each key (a key without word stops the typing), and key counts
  start again with each action (second security review 2026-11-25).
- **Clickable (FR-486).** `PageScripts.read` adds, after the controls, elements whose own
  computed cursor is `pointer` while their parent's isn't, or that have an `onclick` of their
  own, visible, not in or holding a listed control, at most 100 of them and at most 3,000
  elements looked at; kind "clickable"; state from aria (as FR-465) and class names.
- **Safari (FR-487).** `PageScripts.type` gives each character keydown, keypress, beforeinput,
  the value, input and keyup; contenteditable as before through `insertText`, with the key events
  around it.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/BrowserActionTests.swift`
- `macos/Tests/RegressionBusyInputTests.swift`
- `macos/Tests/RegressionRealInputTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

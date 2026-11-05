# Research 005: Browser control

Done 2026-10-22 with 003, 004, 006.

## Options considered (Toni chose the Owner's real Safari)

- **Chrome with remote debugging**: since Chrome 136 the debugging switches are ignored for the
  default profile; only a separate profile can be driven.
  https://developer.chrome.com/blog/remote-debugging-port
- **Chrome extension** (as Playwright MCP Bridge): uses the real Chrome profile, but needs an
  extension in the Chrome Web Store. https://playwright.dev/mcp/configuration/browser-extension
- **Safari WebDriver** (`safaridriver`): separate automation windows, walled off from the
  user's browsing, history, and AutoFill; nothing persists.
  https://developer.apple.com/documentation/safari-developer-tools/webdriver
- **Safari through Apple Events** (chosen, Toni 2026-10-22): AppleScript opens windows and tabs
  and reads URLs and titles; `do JavaScript` runs script in a tab, so pages can be read and
  clicked with the Owner's logins. Requires "Allow JavaScript from Apple Events", which on
  macOS 26 is in Safari Settings → Developer (shown after "Show features for web developers" in
  Advanced), may ask for the Mac's password, and only the Owner can turn it on.
  https://developer.apple.com/forums/thread/836299
  Also needs Automation permission for Safari (setup asks, as for Notes and Messages).

## Limits

- Screenshots of a page need the screen on and unlocked and Screen Recording permission (spec
  006); reading and clicking through JavaScript don't.
- JavaScript clicks are not "real" user gestures: sites that demand one (some file pickers,
  pop-ups) won't respond. Computer control covers those when the screen is on.
- Web pages are written by others and are the most common place for prompt injection: every
  page's text is marked as the website's content, not instructions (spec 002 D6).

## Choices (low-level, Claude's)

- **Claude's window**: Latchkey opens a Safari window of its own and remembers its id; tools
  act on that window's tabs only, never on the Owner's other windows. If the Owner closes it,
  the next call opens a new one.
- **Reading a page**: one script returns title, URL, visible text (at most 40,000 characters,
  with `offset` to continue), and the page's links, buttons, and fields, each tagged with a
  short reference (`e12`) stored as a `data-latchkey` attribute so clicks find the same element.
- **Waiting**: after opening, going back, clicking, or submitting, wait until a *different*
  document has finished loading (its `performance.timeOrigin` changed and `readyState` is
  complete), at most 15 s; a click that doesn't navigate counts as done after 1.5 s. Waiting for
  `readyState` alone answered with the old page (live check 2026-10-23): the old page, or a new
  window's blank page, is already "complete".
- **Typing**: sets the field's value and fires `input` and `change` events, the way frameworks
  expect; `submit` presses Enter by submitting the field's form.
- **Scripts from Claude** (`browser_script`, Read & write level): runs Claude's own JavaScript in
  the tab; result as text. Passed as an argument, never pasted into the AppleScript.

## Claude's page as a tab in the Owner's window (2026-10-29)

Toni chose a tab in the Owner's window as the default, opened in the background, with a window of
its own as the other choice. Safari's scripting dictionary (`sdef /Applications/Safari.app`) gives
a tab only `index`, `URL`, `name`, `visible`, `source`, `text`, and a hidden `pid` (its web
content process): no id that lasts. How to know which tab is Claude's:

- **Position only**: breaks as soon as the Owner closes a tab to the left (Claude's tab moves) or
  closes Claude's tab (another slides into its place): Claude would read the Owner's tab. Rejected.
- **Address**: pages change their own address, and the Owner may have the same page open.
  Rejected on its own.
- **`window.name`**: lasts across pages in a tab, but WebKit clears it when a top-level page goes
  to another site (WebKit changeset 209076, 2016:
  https://lists.w3.org/Archives/Public/public-webappsec/2016Dec/0002.html). Rejected.
- **Web content process id**: changes when the tab goes to another site, and same-site tabs may
  share one. Rejected.
- **Position, count, and a mark on the page** (chosen): a random token set as a hidden property on
  Claude's page before every script. It survives the Owner's tabs moving, and is lost when the
  page changes; Claude's own navigation is covered by accepting the unmarked tab at its position
  while that navigation is recent, when the tab count is unchanged and the tab shows the address
  Claude loaded or its marked page said it was going to (plan D6). Anything less certain counts
  as lost: the tab is left alone and noted (FR-418). Cost: a page that navigates by itself between
  Claude's calls (a timed redirect) makes Latchkey lose its tab, which then stays open and is
  named in Left Behind. The check runs a one-line yes/no script in the tab at Claude's position
  and in tabs at Claude's address only; no other tab of the Owner's runs anything.
- **Deciding in Swift or in AppleScript**: in Swift (chosen), from a survey script that answers
  only yes/no flags per tab, so the decision is unit-tested; costs one more `osascript` per use
  (about 0.1 s). The acting script checks again (count, and mark or loading address), so tabs
  changing in between are caught.

Security review fixes (2026-10-29):

- **When does "Claude's page is loading" hold?** The first version used the time of Claude's last
  use, which every Apple Event refreshes (the survey included), so the allowance for an unmarked
  tab could stay open for ever and the mark could end up on an Owner's tab moved into Claude's
  place. Options: a fixed time after Claude's own navigation only (still accepts any tab in that
  time); that plus the tab showing the address Claude loaded (chosen); or no allowance at all
  (every click to another page would lose the tab). For clicks the address isn't known ahead:
  options were the link's href (misses buttons, forms, and script navigations), reading the
  unconfirmed tab's address in Swift (reads the Owner's tab), or the page's own Navigation API
  `navigate` event, noted by Claude's marked page (chosen; WebKit has it, checked in the WebKit
  view test). Redirects change the address: the common ones (to https, to www., a final /) are
  accepted as spellings; others lose the tab, which is safe and named in Left Behind.
- **Checking between survey and action**: the count alone missed a tab dragged into Claude's
  place. The acting script now repeats the mark check (or the loading-address check) itself,
  in one Apple Event with the action, so nothing happens in between.
- **The page's note of where it is going** (second finding): it was a page property, so a page in
  Claude's tab could write any address and, through a line break, add parts to the script's
  answer, and every script could restart the allowance. Options for keeping it: a page property
  (rejected), a property set from the AppleScript side (the page still sees and changes it), or a
  variable inside the listener's closure, read through a getter defined non-configurable and
  without a setter (chosen: page code can't write the variable or replace the getter once
  Latchkey's is there; Latchkey ignores a getter that is configurable, has a setter, or is
  enumerable). For the answer's shape: line breaks removed in the AppleScript plus the note
  JSON-encoded and checked as one web address in Swift (chosen), or the whole answer as JSON from
  AppleScript (AppleScript has no JSON encoder; more code for the same result). Limits: one note
  per action of Claude's, and the allowance's start set at most once per action. What remains: a
  page that installs an identical getter before Latchkey's first script, or that really goes to
  an address of its choosing, can still name the address, once per action; it still takes the
  Owner's tab sliding into Claude's place, with the same count, at that address, within 16 s,
  for Latchkey to use the wrong tab.

Other choices (Claude's): the new tab goes at the end of the front window (where Safari puts new
tabs; no current tab means a non-browser window, skipped); `new_tab` in a tab loads in Claude's
one tab rather than adding tabs to the Owner's window (FR-416: fewer of Claude's tabs to track
and close; Claude can still go back); a changed setting closes the old tab or window at the next
page rather than at once (nothing in progress is cut off, nothing is left open); the Left Behind
entries are recorded by the browser itself through a callback, so tab and window wording comes
from one place. Not verifiable without the real Safari (tests never touch it): that
`make new tab` leaves the current tab alone, and that a background tab draws in time for the
screenshot; both are standard Safari scripting behavior.

## Claude's window across restarts (2026-10-29)

A live check found that an update of Latchkey forgot Claude's Safari window, which then never
closed (FR-411). Where to keep the window's id: user defaults (tests would need a stand-in, and
other programs can write them), the activity log (encrypted and append-only, wrong shape for a
value that changes on every use), or a small JSON file in the support folder (chosen: plain,
private to the user, deleted once the window closes). Safari's window ids are only meaningful
while the same Safari runs, so the file also names Safari's process id and launch time, and a
mismatch means start fresh rather than risk closing one of the Owner's windows. The Owner's own
windows are never adopted.

A window Safari brings back after its own restart has a new id (Toni asked for it to close too,
2026-10-29). Ways to know it again: a mark set in the page (`window.name`, session storage),
which a cross-site navigation clears and Safari may not restore; the window's title, which is
the page's; or the addresses of its tabs, noted each minute (chosen). It is found only when
exactly one visible window has exactly those tabs; two matches, or none, leave every window
alone. The security review pointed out that adopting such a window would let Claude act in one
of the Owner's windows if the match were wrong, so it is only ever closed, after checking again
that it is still the one window with those tabs, and it is looked for only in the first 5
minutes after Safari starts, so a window the Owner opens later with the same tabs never counts. The remaining risk is closing an Owner's window
with exactly the same tabs while Claude's was not brought back; judged rare enough. Claude's tab
in the Owner's window (the default since 2026-10-29) can't be found this way, since the Owner's
restored tabs look the same; it is left alone and noted (FR-418), asking Safari only whether
some tab shows Claude's last address.

windows are never adopted; a window Safari restores after its own restart stays open.

Security review, third round (2026-10-29): the page's note of where it is going can be forged
by the page (the mark's token is on the page too, so no secret can tell Latchkey's getter from
the page's). So a note counts only for an address on the site of the page Claude's tab shows
(http or https, with or without www., the same port), and once a note opened the allowance it
can't move it forward until it closes, so interleaved calls can't keep it open. Cost: a click
that takes Claude's tab to another site loses the tab; it stays open, is named in Left Behind,
and Claude's next page opens in a fresh tab. Changed 2026-11-01 (Toni: the use case must
work): the address of the link Claude clicked, which Latchkey's own click script reads from the
link (not a note the page writes), counts on any site when it was the same before and after the
click (so a page's click handler can't name another site); the tab is still taken only at
Claude's position, with as many tabs as before, while it shows that address loading.
Fourth round (2026-10-29): the note is compared with the site Claude's tab showed before the
script ran, and only Claude's own click, typing, or back may open the allowance; a read or a
script of Claude's never does. What remains: a page can name one address on its own site per
click of Claude's, and using it against the Owner would still need an Owner's tab at that
address to slide into Claude's place, with the same tab count, within 16 s. Accepted.

## Real Safari check (2026-10-29)

The live check with app 0.8.47 (Claude's page a background tab in the Owner's window) found two
faults the stand-in Safari didn't show.

**A same-site click lost Claude's tab.** Reproduced with scripts against real Safari 27.0.1, in
a window opened for the purpose, timing the Navigation API `navigate` event with
`performance.now()`:

- A link (`a.click()` on a Wikipedia article link): the click script returned, then the page
  fired `beforeunload`, then `navigate` (`push`, the new address). The separate
  `do JavaScript` that took the note right after the click sometimes ran before the event (note
  empty, old page still marked) and sometimes after the new page had already replaced the old
  one (no note, no mark); 0.5 s later the tab showed the new page, unmarked. With no note and no
  mark, the next survey found no tab of Claude's: lost, as the Owner saw.
- `location.href = …` in a script: `navigate` fired during the script, but by the next
  `do JavaScript` Safari had replaced the page (new `timeOrigin`, no getter): the note was gone.
- `history.back()`: no `navigate` in the old page before it went; the page came back from
  Safari's back-forward cache with its mark (so back usually kept the tab, by luck).
- The stand-in delivered every note in the separate step, so its tests passed.

Options: (a) take the note in the same `do JavaScript` as the script (catches what fires during
the script: `location.href`, handlers that navigate); (b) the click script answers the address
of the link it clicked, read after the page's click handlers (Google and others rewrite links
on click), and the back script the address of the entry back goes to (`navigation.entries()`);
(c) the acting AppleScript asks again for the note for a short while after a click, typing, or
back (catches buttons and forms whose event comes after the script, while the old page is
still there); (d) accept any address on the same site for a while after Claude's click (no
note needed, but an Owner's tab at any address of that site sliding into Claude's place would
count: wider than the security review accepted). Chosen: (a), (b), and (c) together; (d)
rejected. All three are the page's word, like the note, and count only as notes do: an address
on the site Claude's tab showed, one per action, and only in Claude's click, typing, or back.
The wait asks every 0.05 s for up to about 0.6 s and stops at a note, at a page without
Latchkey's getter (`takeDestination` answers `null` there), or when the window's tab count
changed, so it runs only in Claude's tab as the guard found it. Cost: a click that doesn't go
anywhere takes about 0.6 s longer (the 1.5 s wait for a click that may navigate was already
there). What still loses the tab: a redirect other than the usual spellings (a search form
that redirects to an article), a page that navigates later by itself, a script of Claude's that
navigates (the fourth round's rule), and a link to another site.

**A long page came back in one piece.** The page script cut the text at 40,000 characters, but
the answer added the list of links, buttons, and fields: on the Wikipedia article, 400 links
(about 31,000 characters, most of it full `https://en.wikipedia.org/wiki/…` addresses), so
71,455 characters in all, over Claude's result size. The answer said only "read on with an
offset", not which, and compared JavaScript's length (UTF-16) with Swift's character count;
and `browser_read` with a url ignored an offset given with it (it opened the page from the
start). Options for fitting: page the links too (needs their place in the text; more code), cut
the list at a share of the answer and give the text the rest (chosen: 20,000 for the list, a
link on the page's own host shown by its path, those left out counted), or drop the list from
later parts (Claude loses the references it needs to click). The answer now names the offset
to read on from, positions count in UTF-16 as `offset` does, and a url with an offset reads from
the offset.

How it was checked: `macos/scripts/safari-check.sh` builds Latchkey's own `SafariBrowser` and
page scripts into a small program and runs them against real Safari from a terminal. A test in
the test host was tried first: the test host is its own app to macOS, and its first Apple Event
to Safari opened an Automation prompt; while that prompt waited (behind the locked screen),
Safari answered no window or tab scripting from any program.

## The Owner's tabs (2026-11-03)

Toni: "Claude needs to be able to access my tabs and windows just like its own." Low-level
choices (Claude's), each with the options weighed:

- **Naming a tab.** Safari's tabs have no id, only a position in a window; windows have an id
  that lasts while the window is open. Options: the window's place front to back and the tab's
  number (changes whenever the Owner clicks another window), the tab's address (two tabs can
  show the same page), or the window's id and the tab's number. Chosen: window id and tab
  number, written `4213.2` (one argument, like the `e12` element references). A bare number
  still works, meaning that tab of the window that holds Claude's page (the old meaning in a
  window of Claude's own), else of the front window.
- **Per call or remembered.** Options: every call names its tab (stateless, but a forgotten
  `tab` would click `e12` in another tab, where `e12` may mean something else), or picking a tab
  makes Claude work there until it opens a page or picks another (as switching tabs did in
  Claude's window). Chosen: remembered, and `browser_act` also takes `tab` so a call can say it
  outright; every answer names the tab it came from, so Claude always knows.
- **Knowing the tab again.** The same machinery as Claude's own tab (plan D6): the mark on its
  page, the survey, the guard in the acting script, the navigation rules. Kept rather than a
  simpler "same position and address" check, because the same-site and click rules are to apply
  to the Owner's tabs too, and because a tab that moved must not be clicked by mistake. One
  addition: a page Safari lets no script into (an empty new tab, Safari's own pages) can't carry
  the mark and could otherwise never be closed, so such a tab is known by the address it had
  when picked. A first version accepted the address Latchkey last saw in the tab instead; its
  test showed that a script of Claude's that sent the page elsewhere then kept the tab (the
  acting script reports the new address), against the rule for Claude's own tab, so the address
  is now fixed at the pick and used only for a page that couldn't be marked.
- **Losing it.** Claude's lost tab is a Left Behind entry (it may still be open, unused). A lost
  Owner's tab is the Owner's own tab: nothing to report there; Claude is told to list again.
- **While locked.** Seen 2026-11-01: Safari answered the first script while locked and then no
  more. Tried again 2026-11-03 at 21:20, the Mac locked: the tab list script (no page script)
  answered three times in a row at once (1 window, 3 tabs), and a page script
  (`document.readyState` in a tab) answered three times too. So the earlier stall isn't the
  rule; when it happens isn't known (perhaps the screen asleep). Options: refuse the Owner's
  tabs while locked (safe, but refuses what works), show the last list seen while unlocked
  (stale), load the tab's address in Latchkey's own browser (a fresh copy, not the tab: a form
  half filled in would be lost), or try Safari and say plainly when it doesn't answer. Chosen:
  try Safari (closest to "just like its own"), with the existing message on a timeout while
  locked; the cost of a stuck Safari is one call that waits 25 s. Claude's own page stays in
  Latchkey's own browser while locked, as before (FR-420). The same evening, still locked, the
  real Safari check (which opens windows of its own) first got its pages slow to load and then
  a window that took more than 25 s to appear, after which Safari answered no script, the list
  included, for a few minutes; by the next try the lock had ended and Safari answered again.
  So opening windows while locked seems to be what stalls Safari; the Owner's tabs are only
  read and acted on, never opened, by this change.

**Checked against real Safari (2026-11-03, `macos/scripts/safari-check.sh`, unlocked).** All
cases passed: the earlier ones (same-site click, a script's navigation lost as designed,
cross-site click, a long page in parts) and the new one, in the check's own window, whose first
tab played the Owner's: listed with the front tab and Claude's tab named, picked, read, a link
clicked, back, the tab in front still in front, closed, and Claude back in its own tab. With
`LATCHKEY_READ_OWNER_TAB=1`: the Owner's real Safari (1 window, 3 tabs) was listed, a tab behind
the front one was read (957 characters, 47 links and fields), and every window's front tab
stayed in front. The check script had stopped building since the screen and permission code
moved (it now compiles `App/Computer/Screen.swift` and a small stand-in for `Permissions`).
- **How long a pick lasts.** In memory only; forgotten at 30 minutes unused (the idle timer) and
  when Latchkey restarts, so a later conversation starts in Claude's own page.

## Keys, hover, scrolling, files, and pictures (2026-11-05)

Toni asked for "all the safari stuff": keys, hover, scrolling, lists, attaching files,
downloading, and pictures while the Mac is locked or its display off, all in the background tab
like the existing actions. Owner-level choices were his (do all of it; working functionality
outranks older limits); the options and low-level choices below are Claude's, least intrusive
first.

- **Keys.** (a) Keyboard events dispatched in the page by a script, with what the browser
  would do by default done by the script where the page didn't take the key (chosen): runs in
  a background tab, in the Owner's tabs, and in Latchkey's own browser while locked; a page
  sees `isTrusted` false, so the rare page that checks it (some games, a few banking widgets)
  ignores the keys, and Command shortcuts that are Safari's own (Command-L, Command-T) aren't
  Safari's then. (b) `CGEvent.postToPid` to Safari: real keys, but Safari sends them to its key
  window's front tab, which is the Owner's, needs Accessibility, and does nothing while locked;
  not tried, as it would type into whatever the Owner has in front. (c) System Events
  `keystroke`: brings Safari forward; rejected without trying for the same reason. Computer
  control (spec 006) stays the way for a page that needs real keys.
- **Hover.** (a) Pointer and mouse events at the element's middle (chosen): opens menus driven
  by `mouseenter`/`mouseover` scripts, which is most of them. A menu that opens only by CSS
  `:hover` can't be opened by any script (the state belongs to the real pointer); the answer
  says nothing new shows and that clicking often works. (b) Moving the real pointer: needs the
  tab in front and the screen; rejected (computer control already does it).
- **Scrolling.** A wheel event first, then the nearest part that scrolls (chosen); the answer
  says where it is. Reading a page lists up to 20 parts that scroll on their own, so Claude has
  a reference to scroll inside; looking at every `div` and the like costs about as much as
  listing links (one layout already done).
- **Lists.** A `select`'s value with input and change (as typing into a list already did, now
  also several options at once), and for lists a page builds itself, a click on the opener and
  on the item whose text matches. Reading lists combo boxes, list boxes, menus, and
  `aria-haspopup` elements so Claude can name them.
- **Attaching files.** (a) A `DataTransfer` of `File`s built in the page from the file's bytes,
  set as the file field's `files`, then input and change (chosen): exactly what a page sees when
  the Owner picks a file, works in a background tab and while locked, and the same objects make
  a drop on a drop place. (b) Clicking the field and answering Safari's open panel through
  Accessibility: real, but the panel is a sheet of the front tab (the tab has to come forward),
  needs the screen and the Mac unlocked; rejected. (c) WebDriver (`safaridriver`): its own
  automation window, without the Owner's tabs, and it needs "Allow Remote Automation";
  rejected. The bytes travel as base64 in the page script; a script longer than 200 KB goes
  through a file only the Owner's account can read, which the AppleScript reads (macOS allows
  about 1 MB for all of a program's arguments). Limit 30 MB together. Reading lists hidden
  file fields too, since most sites hide theirs behind a styled button.
- **Saving files.** (a) `fetch` in the page, with its cookies and session, handed over as
  base64 by a second script (chosen): gets what the page's own link would, also files the page
  made itself (`blob:`, `data:`), in the background, locked included; at most 50 MB. (b)
  Latchkey fetching the address itself with Safari's cookies (`URLSession`): for a file the page
  may not fetch (another site's without its permission); kept as the fallback (500 MB). (c)
  Letting Safari download it (a click on a `download` link): Safari asks per site whether to
  allow downloads, in the front tab, and the saved name isn't known to the script; not tried.
  The file is written new (never over another), named as the server says, else the link, else
  the address, cleaned so it can't leave Downloads or hide itself, and marked with
  `com.apple.quarantine` as Safari's downloads are, so Gatekeeper checks it before it opens.
- **Pictures without the screen.** Tried 2026-11-05 with the Mac locked: `screencapture -l` of
  a Safari window answered "could not create image from window", so no capture of Safari's
  window is possible while locked (ScreenCaptureKit gives the same; Latchkey never gets around
  the lock, spec 001 FR-661). Options: (a) a copy of the page as it is (markup, what fields
  hold, what is chosen, canvases, current picture sources; scripts removed and forbidden;
  passwords as dots) drawn by a WebKit view of Latchkey's own at the window's size and the
  page's scroll position (chosen): a background tab, the Owner's tab, locked, display asleep,
  and lid closed alike, and it keeps what Claude typed; videos, other sites' frames, and some
  effects may be missing, which the answer says. (b) The same address loaded afresh in
  Latchkey's own browser (FR-423 until now): loses what the page holds now; kept for pages
  Safari lets no script into (PDFs, Safari's own pages). (c) Waking the display or unlocking:
  never (FR-661). The copy is also used when the Owner can see the window (FR-423), where
  bringing Claude's tab forward would show in front of him.

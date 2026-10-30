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
that it is still the one window with those tabs. The remaining risk is closing an Owner's window
with exactly the same tabs while Claude's was not brought back; judged rare enough. Claude's tab
in the Owner's window (the default since 2026-10-29) can't be found this way, since the Owner's
restored tabs look the same; it is left alone and noted (FR-418), asking Safari only whether
some tab shows Claude's last address.

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

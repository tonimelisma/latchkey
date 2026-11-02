# Screen states: what works, alternatives, and what other tools do

Research and live tests of 2026-11-01 and 2026-11-02 (Toni: "investigate each and every option").
States that matter: **unlocked** (lid open, or the first minutes after closing it) and **locked**
(after idle, lid open or closed). Latchkey never holds off the lock or unlocks the Mac (spec 001
FR-661, Toni 2026-11-02: "we're not circumventing security").

## Tested with the lid closed and the Mac locked (app 0.8.78/0.8.79, 2026-11-02)

| Group | Works | Notes |
|---|---|---|
| Files, shell, Notes, Messages, reminders, contacts, location, maps | all | |
| Calendar | 7 of 8 | "repeat" inconclusive in the check (didn't re-read); passed unlocked |
| Browser (Latchkey's own WebKit view, Safari's cookies) | all | signed in to Google and GitHub; dialogs answered and told; pop-ups in its page |
| Mail: find, read, organise | all (night of 2026-11-01) | all failed 2026-11-02 while Mail was frozen by a modal alert (below) |
| Mail: write, send, draft | no: queued with `mail_queue` | Mail's window can't be used while locked |
| Computer control, screen pictures | no | see below |

## Alternatives tried, and why they don't work while locked

- **Screen pictures:** ScreenCaptureKit window capture fails ("audio/video capture failure"); no
  active display with the lid closed.
- **Accessibility:** every app's windows show only the app's name as title, with no text and no
  buttons (Safari 8 bits of text, others none); menu bars remain. Mail's windows show as "Mail".
- **Input:** goes to the lock screen's password field; never tried.
- **Mail through scripting (no window):** two sends timed out, and Mail then showed a modal alert
  (`NSAlert runModal` inside the Apple Event handler, seen with `sample`) that no one can answer
  behind the lock: Mail answered no Apple Event from any program, Latchkey included, until
  unlocked. Research: every way of writing the body by script (content, html content, set after,
  twice, paragraphs, visible false, plain format) arrives wrapped as a quote in other mail apps
  (FB11734014, macOS 13 to 27; che-apple-mail-mcp, sweetrb/apple-mail-mcp, cupertino,
  apple-tools, elfensky, UliPrantz). A draft saved cleanly can't be sent by script.
- **Clean mail without Mail's window (research):** direct SMTP with the account's own credential
  (sweetrb, s-morgan-jeffries, parasxos) or a provider API (Microsoft Graph, Gmail). Latchkey
  can't reuse Mail's passwords or OAuth tokens (Keychain access lists), so each account needs its
  own sign-in or app password. Not built.
- **Safari through Apple Events:** answers the first script, then times out (2026-11-01).
- **Virtual display or dummy plug (ServerMode, BetterDisplay):** gives a closed Mac a screen, but
  the session still locks; only useful with the lock weakened. Not pursued.
- **Unlocking (ChatGPT's "locked use"):** an authorization plug-in in macOS's unlock flow that
  unlocks during an agent's turn, covers every display, and relocks on local input. It unlocks
  the Mac, which Latchkey doesn't do.
- **A separate desktop (second user session, macOS VM such as cua's Lume):** isolates the agent
  but has none of the Owner's signed-in apps and data.

## What brings windows forward or takes focus while the Owner uses the Mac

| Where | What it does | Alternatives (to test unlocked) |
|---|---|---|
| Mail: write, send, draft | activates Mail, raises the compose window, pastes files with Mail in front | open the window without activating; fill it through Accessibility in the background (AXSetValue works on background windows in other tools); move it off-screen; paste only when needed; or SMTP/API with no window |
| Browser, a window of Claude's own | a new Safari window may cover the Owner's | tab mode (default); or Latchkey's own browser always |
| Browser, screenshot in tab mode | brings Claude's tab to the front for the picture, then back | Latchkey's own browser draws the page itself (works locked and unlocked, but its cookies are a copy) |
| Computer control | moves the real pointer and types into the front app | per-app Accessibility actions and per-process events (`CGEventPostToPid`), single-window capture (ScreenCaptureKit), as Claude's own computer use, Codex, cua-driver, Peekaboo do |
| Shell with `uses: open` | an app opened through macOS may come to the front | `open -g` (background) by default |
| Notes, Messages, reminders, calendar, contacts, files | none (scripting or frameworks, apps opened hidden) | |

## What others do (research, 2026-11-02)

- **Browsers:** Playwright MCP and chrome-devtools-mcp drive the real Chrome (visible tabs; Chrome
  asks permission per session) or a headless Chrome with an imported cookie file; Claude in
  Chrome is reported to steal focus (anthropics/claude-code#31119); Safari has no headless mode and
  safaridriver opens its own window with a clean session. An off-screen WKWebView with Safari's
  cookies, as Latchkey does, is the only Safari-login route found that works locked.
- **Background computer use:** Claude's own computer use (macOS 15+) works in background windows
  without taking the pointer; OpenAI's Codex reads Accessibility and keeps an agent cursor;
  cua-driver posts per-process events (private SkyLight) and focuses without raising; Peekaboo
  defaults to background delivery. Canvas apps (games, Blender) still need the front.
- **Remote desktop (Screen Sharing, TeamViewer, Jump, Parsec, RustDesk):** show the lock screen and
  a person types the password; privacy or curtain modes blank the screen once unlocked.

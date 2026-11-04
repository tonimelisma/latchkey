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
| Mail: find, read | all | since 0.8.81 also while Mail itself is frozen (account names from Mail's files after 4 s; checked live) |
| Mail: organise (read, flag, move, junk, delete) | all (night of 2026-11-01) | through Mail's scripting: not while Mail is frozen |
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

## Three groups: what gets in the Owner's way (app 0.8.99, 2026-11-02)

Measured by `state-check.sh run` with `focus-watch.swift` (app in front, window on top, new
windows, pointer, clipboard), one group at a time, plus direct live checks. Unlocked run on
0.8.95: 107 of 108 use cases worked; the forward that failed was fixed in 0.8.99 (checked live).

1. **Needs the Mac unlocked and gets in the way**
   - Computer control at a point (click, move, drag, scroll): the real pointer. An app ignores a
     click sent to it alone, so this can't move to group 2.
   - Shell with `uses: open`: what opens doesn't take the keyboard (`open -g`), but its new
     window can still appear above the Owner's.
   - Mail, a reply or forward with files: Mail comes forward for under a second to paste them
     (attaching by scripting erases the quoted original, tried 2026-11-03); and whenever its
     scripting can't make the message, for short moments (opening, pasting, Send), each after a
     pause in the Owner's typing.
2. **Needs the Mac unlocked, stays in the background**
   - Mail write, send, reply, reply all, forward, draft, and new messages with files (0.8.96 to
     0.8.100): made, given files, and sent or saved by Mail's scripting, the window behind and off-screen, the
     text typed with keys sent to Mail alone; nothing came forward in live checks.
   - Computer control of a named app (0.8.93): a picture of its window, its buttons and fields,
     press, type, and keys sent to it alone.
   - Browser in Safari, tab mode; page pictures switch Claude's tab only while its window can't
     be seen, else come from Latchkey's own browser (0.8.90).
   - Computer looking (screenshot, front window's UI, apps): reads only.
3. **Works while locked**
   - Files, shell, Notes, Messages, calendar, reminders, contacts, location and maps; Mail
     find and read; Mail organise (while Mail answers its scripting).
   - Browser through Latchkey's own browser (Safari's cookies copied).
   - Mail sending, queued until the next unlock (`mail_queue`).

## Moving group 1 to group 2: experiments (2026-11-02, unlocked)

- **Mail, window opened without activating Mail:** opens behind the front app, but Mail never
  builds its message text area (no web area in Accessibility, not after raising, focusing,
  making it main, uncovering it, or activating later); the window then wouldn't close until
  Mail came to the front. Dead end.
- **Mail, in front only while needed:** activating Mail as today, the text area exists after
  0.5 to 1.1 s; giving the front straight back and moving the window off-screen (macOS keeps
  40 px on screen), the text **typed as keys sent to Mail alone** (`CGEventPostToPid` with
  Unicode strings) arrived exactly ("äö €" included) with Mail in the background. Setting the
  text through Accessibility (`AXSelectedText`) did nothing in the background. Pressing Send
  through Accessibility in the background did nothing; with Mail in front for 0.9 s it sent
  (checked in Sent). Pasting a file with Cmd-V sent to Mail alone did nothing; Edit → Paste with
  Mail in front works (today's code), but the quick 0.9 s try didn't attach the file. So: two
  short moments in front (opening, sending) instead of 5 to 8 s, the window off-screen, the
  clipboard only for files. Risk: keys the Owner types during those moments go to Mail; waiting
  for a pause in their typing (seconds since the last input event) lowers it.
- **Mail with no window:** only sending directly to the mail server or the provider's API
  (Microsoft Graph, Gmail) is truly in the background and also works locked; each account
  needs its own sign-in for Latchkey (research above).
- **Computer control in the background (Calculator behind other windows):** Accessibility
  presses worked; keys sent to the app alone worked ("2 × 3 Return" computed); a mouse click
  sent to the app alone did nothing; a picture of that one window (ScreenCaptureKit, window
  filter) was complete while covered. The pointer and the front app never changed. An app
  launched without activating opens behind, but its window is on screen.
- **Browser picture:** Safari's window is already captured on its own (covered windows
  work), so the tab can be put in front unseen whenever that window isn't visible to the
  Owner (covered, another Space, minimised is not capturable); when it is visible, a picture
  from Latchkey's own browser of the same address, or the brief switch as today.
- **Shell open:** opening in the background (`open -g`) by default.

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

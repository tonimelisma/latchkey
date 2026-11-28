# 0068. A page's own dialogs (FR-432, decided 2026-11-03)

- Status: accepted
- Date: 2026-11-04
- Alias: plan 005 D9 (`specs/005-browser/plan.md`, "D9. A page's own dialogs (FR-432, decided 2026-11-03)")

## Context and problem

Decision D9 of spec 005's plan (Browser control); requirements in
[requirements/browser.md](../requirements/browser.md). Requirement IDs it cites: FR-432.
The design it belongs to: [design/browser.md](../design/browser.md).

## Decision


Found by trying it in real Safari (2026-11-03, a background tab Latchkey's way, with a page that
shows an alert): while a page waits on its own dialog, every `do JavaScript` in that tab, and
even its `text` and `source`, waits for Apple Events' time limit (-1712); its name and URL still
answer, and so do other tabs at once, also right after (Safari as a whole never stalled).
Setting the tab's URL replaced the page in 0.2 s and closing it worked. Accessibility shows no
sheet for a background tab's dialog (it appears when the tab comes to the front). This is the
most likely cause of the locked-Mac stalls seen on 2026-11-01 (a dialog no one could see or
answer); the time limit was 25 s (ScriptRunner).

- Answers in the page: each page script starts with `PageScripts.dialogAnswers`, which replaces
  `alert`, `confirm`, and `prompt` in the page and the frames it can reach (once per document)
  with ones that answer at once as Claude's action says (default Cancel, no text) and note what
  they said; the same AppleScript run then takes the notes (`takeDialogs`, 2 s limit) and they
  come with the answer, worded as in Latchkey's own browser (`PageScripts.dialogNote`, at most
  5, 200 characters each, no «»). Latchkey's own browser answers through WebKit's delegate the
  same way. `browser_act` takes `confirm` (true: OK) and `prompt_text`, for that action only:
  the answer is passed with the action (never kept as state another call could pick up), and
  the take, in the same AppleScript run right after it, sets the page back to Cancel and no
  text; in one of the Owner's tabs it also puts the page's own dialogs back, so his page
  behaves as before once Claude's script is done (security review 2026-11-03). A page can
  restore its own functions; then its dialog waits, and the next check below says so.
- A page that already waits (its dialog came before the answers were in, e.g. at load): every
  check of a page (the mark check in the survey and the guard, picking, putting a tab back) has
  a 2 s limit (since 2026-11-15, 10 s for the survey and picking and 6 s for the guard right
  after: a busy or paused background tab took longer and was told as a dialog, and an idle
  Safari took 12 s to answer its first script, then 0.5 s; Claude is told it may be either); on -1712 the survey marks the tab waiting, and a script refuses at once
  (`dialogWaiting`). The tab is still Claude's only when it is where it was, shows its last
  address, and the window's tabs (their number, order, and addresses, as one SHA-256
  fingerprint) are exactly as when Claude's mark was last seen there; it can then be loaded
  over (`tabLoad`) or closed, with that address standing in for the mark (security review
  2026-11-03: an address alone could be another tab's). Claude's own window gets a 2 s `do JavaScript "1"`
  first. The Owner's tab is left alone: its dialog shows when he brings the tab forward.
- Options weighed: a shorter time limit for every script (wrongly fails slow pages; still a
  wait), refusing the Owner's tabs while locked (refuses what works, and dialogs happen unlocked
  too), Accessibility checks for sheets (they don't show a background tab's dialog).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/BrowserDialogTests.swift`
- `macos/Tests/BrowserTabTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

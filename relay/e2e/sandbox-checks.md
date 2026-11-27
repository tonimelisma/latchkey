# Sandbox Mac checks to write

## Status (2026-11-27, spec 016 T16 to T19)

Every check below is written, in `relay/cmd/e2e` (`sandbox.go`, `sandbox_apps.go`,
`sandbox_web.go`, `sandbox_more.go`, `watch.go`), and runs in the sandbox Mac (`make -C macos
sandbox`; results in `e2e-results/`). A check that can't run in the copy reports itself skipped
with the reason.

| Check in `e2e sandbox` | Covers (tables below) |
|---|---|
| `tools` | the Mac's tools listed, machines names the Mac |
| `files` | `files` (and the former `e2e mac` files steps) |
| `shell` | `shell`, and the shell half of `composed-text` |
| `browser` | `browser` (Latchkey's own browser, https pages on two sites) |
| `safari` | `safari-claudes-tab`, `safari-cross-site`, `safari-owner-tab`, `safari-actions` (keys, select, hover, scroll, upload, download), `safari-long-page`, `safari-leaves-nothing`, `composed-text` (Safari's half) |
| `notes`, `calendar`, `reminders`, `contacts`, `computer`, `maps` | the per-app groups of the same names |
| `contacts-card-with-note` | new: a card with a note is changed and deleted through the Contacts app's scripting, the note kept, Contacts quit again (spec 007 FR-722a; macOS lets only apps with Apple's Contacts notes entitlement save such a card through the framework; Toni, 2026-11-27: "Via Contacts' scripting"). Passes since 2026-11-27 |
| `front-app-unchanged`, `no-permission-prompts` | the same, sampled during every Latchkey call |
| `sweep` | `sweep` |
| `turned-off`, `offline`, `relay-restart`, `network-cut`, `suspended`, `battery` | `tool-off-disappears`, the offline answer, `silent-network-cut`, `reconnect`, `suspended-account` with `unsuspended-reconnects`, `battery-vs-pmset` (a Mac without a battery was said to have 100%; fixed 2026-11-27, spec 001 FR-065a; the check now wants "no battery" there, and passes) |
| `safari-script-navigation`, `safari-busy-tab` | the same (2026-11-27; each found a Latchkey bug, fixed: a lost Safari tab of Claude's stayed listed as Claude's page; a tab busy right after the pick was called gone) |
| `computer-sidebar-row`, `computer-window-buttons` | the same (the selection read with System Events, which the image lets the test Mac's osascript use) |
| `headless-chrome-profile` | the same (Chrome is in the image) |
| `setup-names-what-is-off` | the same: Mail's control turned off in the copy's permission database, setup's Ask Now pressed with Return, the log line and setup's note read. Passed on the image of 2026-11-26; fails on the image that starts each app once (macOS still answers Mail's control allowed): open, `specs/016-test-strategy/research.md` §7 |
| `report-from-installed-app` | the same: the relay restarted with a throwaway intake and developer key in the copy, sharing turned on, a password typed into a served page, the report opened with that key |
| `keep-awake-real` | the same where the build's keep-awake helper runs; skipped in the sandbox (below) |

Skipped with the reason in each run: `location` (no Wi-Fi in a virtual Mac), `messages`,
`messages-identical-texts`, `mail`, `whatsapp` (no test accounts in the image), `logins` (no
test logins in its Passwords), `pair-preview` (the image is paired once), `keep-awake-real`:
the sandbox build is signed with a self-made identity, no Apple team, and the keep-awake helper
(an `SMAppService` daemon that checks its caller's team) is refused by macOS ("keep-awake off (not
approved in System Settings)"). It would take a build signed by an Apple team in the image: CI's
Apple Development identity (its certificate and key in the sandbox's own keychain, which puts the
team ID on the owner's Mac's disk, so Toni's choice), or the paid Developer Program's Developer
ID; then approving the helper in the copy's background items database, as the image script does
for the other permissions.

What the retired hand-run kits checked, written down when they were removed (spec 016 D2 and
D5, 2026-11-26), for `cmd/e2e sandbox` to port (spec 016 T11, plan D3). Each check runs in the
Tart copy against the installed build, with test data, through a private relay on the host.
The removed code is in git history: `git show 9adb867:<path>` (main, 2026-11-26) for `relay/cmd/maccheck/main.go`,
`macos/Tests/LiveRelayTests.swift`, `relay/cmd/localcheck/main.go`,
`relay/cmd/guidecheck/main.go`, `macos/scripts/safari-check/main.swift` (and its `pages/`),
`macos/scripts/state-check/cases.json` (every case's exact steps) and `focus-watch.swift`.
`docs/regression-coverage.md` maps every former case to its test, check, eval task or Toni's
conditions.

## From `maccheck` + `LiveRelayTests` (the app's connection code, a private relay)

maccheck put a TCP proxy between the app and the relay that could drop traffic without closing
connections, and drove the app through a control file.

| Check | What it checks | Passes when |
|---|---|---|
| `pair-preview` | the pairing code's preview names the account without using the code (spec 001 FR-054) | the preview gives the account's email, and the same code then pairs |
| `battery-vs-pmset` | the app reads the real power source (LiveRelayTests served a test-only `battery_status`; the installed app reports it in every answer's state line, "· N% battery") | percent within 1 of `pmset -g batt`; with no battery (a VM), no made-up percent |
| `tool-off-disappears` | a capability turned off in the app leaves Claude's tool list (SC-08, Constitution III) | its tools are gone from `tools/list` within 10 s, and come back when turned on |
| `silent-network-cut` | the relay notices a Mac whose network vanished without closing (SC-04) | the relay marks the Mac offline within 45 s of the proxy going silent |
| `reconnect` | the app reconnects when the network returns, as a network change (SC-05) | online again within 10 s of the proxy forwarding again (old connections closed) |
| `suspended-account` | the operator suspends the account (spec 001 FR-204) | the Mac is cut off within 10 s; the app shows "suspended", never "sign in again"; a wake or network change is refused; the pairing is not revoked |
| `unsuspended-reconnects` | the suspension is lifted (FR-204) | the Mac is online by itself within 30 s of its next try |

## From `localcheck` (real Claude Code, a pretend Mac)

No sandbox check: Claude calling a tool through the relay is what every eval task does, and the
offline answer after a low-battery goodbye ("offline", the battery percent) is in
`relay/internal/hub/hub_test.go`, `relay/internal/mcpserver/messages_test.go` and `e2e relay`.

## From `safari-check` (Latchkey's `SafariBrowser` against real Safari)

In the copy's Safari, in a window of the check's own (its second tab plays one of the owner's
tabs), local pages served from 127.0.0.1 (`actions.html` and `files/`, in git history).

| Check | What it checks | Passes when |
|---|---|---|
| `safari-claudes-tab` | same-site clicks keep the tab Claude works in (spec 005 FR-403) | the click's answer is the new page, `tabs` lists it as Claude's, back and a second click stay in that tab |
| `safari-cross-site` | a click to another site | the new site reads, twice, and the tab is not lost |
| `safari-script-navigation` | a script that navigates away | Latchkey no longer uses the tab and has forgotten it |
| `safari-long-page` | a long page comes in parts | each part is within the result limit, names where to read on, and the offset reads on |
| `safari-owner-tab` | another tab is listed, read, clicked, gone back in and closed in the background (FR-424 to FR-431) | front tab and Claude's tab named; the front tab stays in front; one tab left; Claude works in no Safari tab after |
| `safari-actions` | keys, hover, scrolling, lists, files in and out, the picture copy, in a background tab (FR-433 to FR-440) | keys and Enter send the form, Escape reaches the page, Tab moves focus, cmd+a and Backspace clear; select one, several, a list the page builds, and a missing option refused naming those there are; hover opens the menu; scroll 500 px, a box to its bottom, back to top; a file and a 3 MB file uploaded, one dropped; a link's file, a file the page made, a 3 MB file and the tab's PDF saved; the copy for a picture holds the page with `<base>` |
| `safari-leaves-nothing` | the check's own clean-up | the app in front and every front tab stay; no window and no file in Downloads of the check's left |
| `safari-busy-tab` | a tab that answers its first script late is called busy, not a dialog (case `browser_busy_tab_not_called_dialog`) | a tab whose script waits 12 s is said busy first, a dialog only maybe |
| `composed-text` | text reaches Safari and the shell composed (case `browser_safari_text_composed`) | a script `'é'.length + ' ' + 'é'.charCodeAt(0)` in a Safari tab of Claude's answers `1 233`; `printf '%s' 'é' \| od -An -tx1` shows `c3 a9` |

## From `state-check` (each capability against the real apps)

One check per former use-case group, run unlocked in the copy with seeded data (spec 015's
fixtures), every created item tagged and swept at the end. Exact steps per case: `cases.json`
in git history.

| Check | Former cases | Passes when |
|---|---|---|
| `notes` | `notes.*` (16) | find, search, read; create (chosen, default, new folder: said made), append, edit, replace, rename, move, checklist read back as `- [ ]`/`- [x]`; delete note and folder go to Recently Deleted |
| `messages` | `messages.*` (3) | conversations, search and read answer (where the image has a test Messages account; else skipped with the reason) |
| `files` | `files.*` (13) | list, Spotlight search, create folder, write, append, edit, read, details, copy, move, a PDF's text, an image, trash, each seen on disk |
| `shell` | `shell.*` (9) | run, a long command as a job checked to done, input, stop, job list, declared writes outside the allowed places, the local network, the internet, `open -g` with `uses: open` |
| `browser` | `browser.*` (19) | open, read, click same and other site, back, script, type and submit, keys, select, hover, scroll, upload, download (link and PDF), confirm dialog, tabs, screenshot, close, on served pages |
| `logins` | `logins.list`, `logins.sign_in`, `logins.other_site`, `logins.import_folder_unreadable` | sites listed without a password; a served sign-in page signs in with a test sign-in Claude fills; another site gets nothing; the import folder can't be read by Claude |
| `computer` | `computer.*` (4) | screenshot, front window's UI, apps, a key, with Accessibility and Screen Recording granted in the image |
| `calendar` | `calendar.*` except the two invitation cases | overview, search, free time, create with an alert, read, move keeping its length, repeat said, delete with span future |
| `reminders` | `reminders.*` (8) | lists, create list and reminder with due time, update, complete and reopen, completed list, delete, delete list with its count |
| `contacts` | `contacts.*` (11) | overview, search, read, create, update, group create, add, remove, rename, delete, card delete |
| `maps` | `maps.*` (5) | places, directions, transit, address, reverse; or the answer says Apple Maps limits the searches, never "found nothing" for a place not searched (case `maps_not_searched_is_not_nothing_found`) |
| `sweep` | `sweep.*` (6) | nothing tagged is left in Notes, Contacts, Calendar, Reminders, Downloads, or Claude's pages |
| `front-app-unchanged` | `regressions.never_disturb_front_app` (was `focus-watch.swift`) | during every check above but computer control and `open`: the app in front, the top window, the pointer and the clipboard stay, and no other app opens a window |
| `no-permission-prompts` | `regressions.never_disturb_no_permission_prompts` | no macOS permission question appears during the checks |
| `setup-names-what-is-off` | `regressions.setup_ask_now_says_what_is_off` | with an app's permission refused in the image, setup names it and where to turn it on |
| `computer-sidebar-row` | `regressions.computer_press_selects_sidebar_row` | a press on a row of Finder's sidebar (or its cell or text) selects the row |
| `computer-window-buttons` | `regressions.computer_window_buttons_named` | a window's untitled buttons are named by kind (close, minimise, zoom) |
| `messages-identical-texts` | `regressions.messages_delete_uber_code_texts` | of two identical texts from a test account, `messages_delete` deletes the one named (where the image has a Messages account) |
| `report-from-installed-app` | `regressions.report_holds_the_chats_pages` | with sharing on and a test intake key, a report from the installed app holds the chat's pages with their fields blanked |
| `keep-awake-real` | `regressions.machines_keep_awake_real` | keep-awake on makes `pmset -g` show SleepDisabled 1 (if the self-signed helper is refused, the check says so; plan D3) |
| `headless-chrome-profile` | `regressions.shell_headless_chrome_profile` | if Chrome is in the image: print-to-PDF with `--user-data-dir` in the scratch folder writes the PDF |

## Eval tasks to write

- **The relay-setup guide** (was `cmd/guidecheck`, `docs/setup-with-claude.md`): claim a fresh
  relay with its setup code, pair a Mac, approve a client, have Claude call a tool through it;
  and recover the account with a code from `relay account recovery-code`. It doesn't fit spec
  015's task format: a task's `setup` and `check` lines are `e2e fixture` commands run inside
  the test Mac and score the Mac's end state, while this one's end state is a new relay on a
  hosting account (the guide's Google Cloud project, its setup code from the server's log) and a
  passkey made in a browser. It needs its own runner: Claude Code following the guide against a
  throwaway host, then guidecheck's claim, pair, tool call and recovery as the check. Until then
  the claim and recovery pages are covered by `relay/internal/server/e2e_test.go` ›
  `TestClaimAndRecoverInBrowser`; the guide end to end stays NOT VERIFIED since its real run of
  2026-10-31.

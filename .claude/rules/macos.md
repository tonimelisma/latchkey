---
paths:
  - "macos/**"
---

# macOS app rules and gotchas

- `macos/project.yml` is the source of truth for the Xcode project. Edit it and run `xcodegen`;
  never hand-edit the generated `.xcodeproj` (it is gitignored).
- Real Mac app only: Apple-supported APIs and standard approval prompts. No Terminal steps, no
  sudoers edits, no private frameworks where a public API exists (Constitution IV).
- Power assertions (`IOPMAssertion`, `caffeinate`) prevent idle sleep but NOT lid-close sleep.
  Only the root-only `SleepDisabled` setting (`pmset -a disablesleep 1`) does; the helper daemon
  owns it.
- Re-apply and read back `SleepDisabled` on every power-source change and wake; reports say it can
  be lost on Apple silicon when the charger is plugged or unplugged.
- Always restore sleep: on quit, when the helper's client disconnects, and at every helper start.
- Swift 6: a closure written inside a `@MainActor` type (or an actor) and handed to an Apple API
  inherits that isolation, and Swift traps at the closure's first line when the API calls it on
  another thread. Every callback Apple may call off the main thread (ASWebAuthenticationSession
  completion, XPC invalidation/interruption, NSWorkspace completions, NWPathMonitor, URLSession
  ping) must be written `{ @Sendable … }` and hop with `Task { @MainActor in … }`. This crashed
  0.1.0 and 0.1.1 at sign-in; `PairingTests` calls the handler from a background thread.
- An `LSUIElement` app's windows are invisible to the Dock and Cmd-Tab: switch the activation
  policy to `.regular` while a window is open (`WindowPresence`).
- `Bundle(path:)` caches by path; to see what is on disk now, read `Contents/Info.plist`.
- The `SMAppService` helper must be signed with the same identity as the app, or macOS won't run it.
  XPC listener must check the caller's code-signing requirement.
- Not sandboxed (later capabilities need Full Disk Access, Apple Events, Accessibility). Hardened
  runtime on.

- Swift 6 rejects Apple's `kAX…` CFString globals (e.g. `kAXTrustedCheckOptionPrompt`) as shared
  mutable state; use the constant's string value.
- `NSRegularExpression` patterns written as Swift raw strings need ICU escapes (`\x{1B}`), not
  Swift's `\u{1B}`.
- AppleScript sent with `osascript` must compile: `ScriptSyntaxTests` compiles every script with
  `osacompile` (reserved words like `before`/`after` as variable names break a script).
- Shell: `macOS sed` doesn't turn `\n` into a newline in replacements, and `make … | tail` hides a
  failed build; use `set -o pipefail`.
- Scripted edits (Python `str.replace`) must assert the old text is present: after `make fmt`
  rewraps a line, a replace silently does nothing. 0.7.0–0.7.1 shipped without Browser and
  Computer control registered because of this; `everyCapabilityIsRegistered` now guards it.
- Tool results go to Claude as text only: with `structuredContent` present, Claude's apps show it
  instead of the text (live check 2026-10-22: shell output, the Mac state line, and message
  marking all vanished).
- AppleScript variables must not be app terms (`kind` in Messages, `before`/`after` everywhere);
  `osacompile` doesn't catch app terms. Prefix variables (`targetKind`, `theText`).
- Debug and test builds are their own app to macOS (Toni, 2026-10-25): bundle ID
  `net.melisma.latchkey.dev`, helper `net.melisma.latchkey.dev.helper`, link scheme
  `latchkey-dev`, data folder `Application Support/Latchkey Dev`, shown as "Latchkey Dev". So a
  test copy has its own user defaults, Keychain items, privacy permissions, and helper, and
  doesn't claim `latchkey://`. Why: while both were `net.melisma.latchkey`, an uninstall test
  erased Toni's pairing twice (2026-10-22), and a leftover Debug build, which carries the
  debugging entitlement, could borrow the installed app's permissions. The names live in
  `Shared/AppIdentity.swift` and, per configuration, in `project.yml` (`LATCHKEY_APP_ID`,
  `LATCHKEY_URL_SCHEME`, `LATCHKEY_DISPLAY_NAME`); never write the identifier as a string
  elsewhere. The Release names (`net.melisma.latchkey`, its `.helper`, `latchkey`, `Latchkey`) must
  never change: the installed app's pairing, log key, settings, and permissions are filed under
  them (`IdentityTests` pins them). A Debug app run by hand needs its own pairing, permissions,
  and helper approval.
- Tests still must never touch real storage: not `UserDefaults.standard`, the Keychain, or
  `DeviceIdentity` (the separate identity is a second fence, not a licence, and a Debug app run
  by hand keeps real data under it). The real `KeychainVault` changes nothing under XCTest;
  pairing tests inject a `MemoryVault`. The Keychain calls themselves are tested only against a
  throwaway service name (`KeychainTests`), never the app's own.
- A password search can't ask for all matches together with their data
  (`kSecMatchLimitAll` + `kSecReturnData` is errSecParam, -50). 0.8.4–0.8.7 read the pairing and
  the activity-log key that way, so every restart found neither: the Mac came up unpaired and a
  new log key replaced the old one. Nothing caught it because every test used a stand-in vault
  and the app wasn't restarted after pairing. Count matches without data, then read the one;
  and after any change to stored data, restart the installed app and check it still starts
  paired (`install.sh` prints the start line).
- Never call `NSApp.terminate` from inside a main-queue block (a dispatch source handler,
  `DispatchQueue.main.async`): with `.terminateLater`, AppKit's wait for the reply runs nested in
  that block, the serial main queue never runs again, and the app hangs forever (SIGTERM, 0.8.2).
  Schedule it with `NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)`.
- Moving stored data to a new place must be all or nothing: delete the old copy only after the
  new one is written and read back, and never count a move done when the old data exists but
  couldn't be read. 0.8.4 read the old pairing key with a stricter, prompt-less Keychain query,
  got nothing, marked the move done, and deleted the old settings: Toni had to pair again
  (2026-10-24). Read old items the way the old version read them, or, when old data can be
  forged by other programs (user defaults), don't move it at all.
- "Couldn't read it" is not "isn't there" (2026-10-25): never write a Keychain item because a read
  returned nothing. `Keychain.lookup` tells no item from an unreadable one; only "no item" may
  lead to a write (the activity-log key was replaced that way on 2026-10-24). And don't test
  unreadable items against the real Keychain: an item with an access list that trusts no program
  makes macOS show a password prompt on Toni's screen and hangs the test run.

- Text that arrives from the network (client names, hosts) goes into SwiftUI with
  `Text(verbatim:)`, never a string literal with interpolation (those are parsed as Markdown).
- Anything decided at start must not read state that only arrives a moment later. The setup
  window opened on every start until 0.8.12, because "is this Mac paired?" was read from the
  connection's status before the connection had reported (FR-205). Set such state from what is
  stored, then start the asynchronous work. After an install, check that a set-up Mac shows no
  window: `osascript -e 'tell application "System Events" to tell process "Latchkey" to count windows'` is 0.
  (System Events also reports 0 for SwiftUI's Settings and Activity windows when they are open;
  `CGWindowListCopyWindowInfo` is the reliable check.) Permissions can read wrong for a moment at
  launch too (the window opened over a finished setup on 2026-10-27; a new location manager
  reports "not determined" until its first authorization callback). Every permission state is
  done, missing, or not known yet (`SetupStep`); only "missing" opens setup, and a paired Mac
  waits for the unknowns to settle (FR-621). `install.sh` now checks the window count, keep-awake,
  and the helper's version after every install (FR-622) and fails when one is wrong.
- Never pause, disconnect, or turn down capabilities on the installed app for a check: Toni's own
  Claude sessions use it (a live Pause test stalled one of his sessions mid-order, 2026-10-26).
  Test those in unit tests or with `make mac-check`. Run `claude -p` live checks from outside
  the repository: inside a worktree the project's end-of-turn hooks make that session commit
  and push the worktree's work.
- Settings… sets the activation policy to `.regular` and activates before `openSettings()`, the
  usual advice for menu-bar-only apps (otherwise the window may not open or opens behind).

- The keep-awake helper keeps running across installs: launchd doesn't restart it when the app
  is replaced. Anything it reads from its own file must be read once at start (its team ID for
  the signature check failed with UNIX error 2 after the next install, so it refused every app
  connection: keep-awake was silently off from 2026-10-25 until 0.8.19). Since 0.8.19 it ends
  itself when it sees its program replaced; launchd starts the new one only after its 10-second
  wait, so the app retries every 12 s (up to 5 times). After an install, check
  `pmset -g | grep SleepDisabled` is 1 while keep-awake is on.

Add new gotchas here as they are discovered.

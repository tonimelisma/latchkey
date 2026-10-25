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
- Tests run in a debug copy of the app with the same bundle ID: it shares the installed app's
  user defaults and Keychain. Tests must never touch `UserDefaults.standard`, the Keychain, or
  `DeviceIdentity` (an uninstall test erased Toni's pairing twice on 2026-10-22);
  the real `KeychainVault` changes nothing under XCTest; pairing tests inject a `MemoryVault`.
  The Keychain calls themselves are tested only against a throwaway service name
  (`KeychainTests`), never the app's own.
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

Add new gotchas here as they are discovered.

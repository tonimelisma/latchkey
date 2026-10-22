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

Add new gotchas here as they are discovered.

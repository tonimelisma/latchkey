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
- Always restore sleep: on quit, when the helper's client disconnects, and on helper startup with
  no client.
- The `SMAppService` helper must be signed with the same identity as the app, or macOS won't run it.
  XPC listener must check the caller's code-signing requirement.
- Not sandboxed (later capabilities need Full Disk Access, Apple Events, Accessibility). Hardened
  runtime on.

Add new gotchas here as they are discovered.

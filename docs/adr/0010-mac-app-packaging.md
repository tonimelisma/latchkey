# 0010. Mac app packaging

- Status: accepted
- Date: 2026-10-19
- Alias: plan 001 D9 (`specs/001-core/plan.md`, "D9. Mac app packaging")

## Context and problem

Decision D9 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-070, FR-071, FR-072, FR-669, FR-670, FR-072d, FR-667, FR-072c, FR-079, FR-074, FR-210, FR-078, FR-077, FR-075.
The design it belongs to: [design/core.md](../design/core.md).

## Decision

Serves FR-070, FR-071, FR-072, FR-669, FR-670; Constitution IV.
- Public download (FR-670, 2026-11-09): `make install` (since 2026-11-23 on the commit CI tagged,
  `mac-tag.yml`, run by the Mac's updater) builds one disk image
  for everyone (`package.sh` empties `LATCHKEY_DEFAULT_RELAY_HOST`, and checks the app carries
  none), installs it, and after the install's checks pass scripts/publish.sh publishes GitHub
  release `mac-<x.y.z>` with the asset `Latchkey.dmg`, marked latest, so
  `releases/latest/download/Latchkey.dmg` is always the newest. It mounts the image first and
  refuses one holding the relay's address or the server's names. The Linux releases are made
  with `--latest=false`. Only the newest three Mac releases are kept (tags stay): the Linux
  program and its installer read GitHub's 50 newest releases, and a Mac release per increment
  would push theirs out of that list. Options weighed for the image: one for the maintainer with the
  default relay and one public (two builds per install, two images to keep apart), or one
  without it (the maintainer's app is paired already; a new pairing types the address): one image.
- New-version notice (FR-669): `Updates` (App/Updates.swift) reads
  `api.github.com/repos/tonimelisma/latchkey/releases?per_page=50` a minute after start, then
  every 24 hours, in an ephemeral session (no cookies, no credentials). Only `mac-<numbers>` tags
  that are neither drafts nor prereleases count; versions compare number by number. The page
  opened is built from the tag, never taken from the answer. The menu shows "Download Latchkey
  x.y.z…" above Quit and Settings → General shows the version with Download…; either opens the
  release page in the Owner's browser (they asked). Off when Sparkle has a key, and in Debug and
  test builds. An unreachable or unreadable answer changes nothing; a readable list with nothing
  newer clears the notice. Weighed: Sparkle without notarization (needs an update key and a
  feed per release, and installs over a quarantined app Gatekeeper may then block) against a
  notice (the maintainer's pick: installing stays his users').
- Signed updates (FR-072 to FR-072d, decided 2026-11-23: "implement sparkle"; built while he was
  away, details below are Claude's proposals for his review, research.md "Signed updates
  without a Developer ID"):
  - Sparkle 2 (already pinned) with an EdDSA update key: its public half is
    `SPARKLE_PUBLIC_ED_KEY` in `Config/Base.xcconfig` (public), the private half
    `SPARKLE_PRIVATE_KEY`, in the release Key Vault (until 2026-11-26 a secret of the environment `release`). No Developer ID: Sparkle checks
    its own signature, and the update is signed with the same development certificate as the
    installed app, so its permissions and pairing carry over.
  - Info.plist: `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate` (silent download, no window:
    Constitution IV), `SUScheduledCheckInterval` 3600, feed
    `releases/latest/download/appcast.xml` (the Mac release is the one marked latest; Linux
    releases are `--latest=false`).
  - `UpdateGate` (App/Updates.swift), Sparkle's delegate: `willInstallUpdateOnQuit` keeps the
    install block and returns true; every minute it checks the running-call marks (FR-667, the
    same rule as `install-lib.sh`'s `idle_verdict`) and, once idle, runs the block outside any
    main-queue job (Sparkle quits, replaces, relaunches). "Check for Updates…" stays in the menu
    and Settings (the Owner asked, so Sparkle's own window may show).
  - Build number (FR-072d): x·1,000,000 + y·1,000 + z, set by `package.sh`
    (`CURRENT_PROJECT_VERSION`) and checked in the built app; `UpdateGate.buildNumber` and
    scripts/appcast.sh use the same rule. Earlier builds all had build number 1, below every
    release under this rule.
  - CI (FR-072c), `.github/workflows/mac-tag.yml` job `release` on `macos-26`, environment
    `release`: fetches the secrets from the release Key Vault with the job's
    GitHub identity token (OIDC, no stored credential), imports the certificate (`MAC_CERTIFICATE_P12`, `MAC_CERTIFICATE_PASSWORD`) into a
    keychain of the run's own, writes `Local.xcconfig` from `MAC_DEVELOPMENT_TEAM`, runs
    `package.sh` with `XCODEBUILD_SIGNING` (manual signing with that identity), zips the app
    with `ditto`, signs the zip with Sparkle's `sign_update`, writes the feed with
    scripts/appcast.sh, and publishes with `publish.sh <version> <zip> <appcast>` (which adds
    the two assets when the Mac published the release first). Without the secrets it warns and
    builds nothing. `ci.yml`'s Mac jobs compiles every macOS change on a pull request and runs the
    update tests, signed ad hoc.
  - Until the first signed release is installed on the maintainer's Mac, the Mac's updater keeps
    installing tags; after that Sparkle does, and the updater can go (`docs/STATUS.md`).
- Project: generated by XcodeGen from `macos/project.yml` (text, reviewable, no `.pbxproj` merge
  conflicts). The generated `.xcodeproj` is not committed.
- SwiftUI `MenuBarExtra`; `SMAppService.mainApp` for start at login. The app is an agent
  (`LSUIElement`) and switches its activation policy to `.regular` while a window is open, so it
  shows in the Dock and Cmd-Tab, and back to `.accessory` when the last window closes (FR-079).
- Tests with Swift Testing; formatting with swift-format (ships with Xcode).
- Hardened runtime, Developer ID signing, notarization. Not sandboxed: later capabilities (Full Disk
  Access for Messages, Apple Events, Accessibility) are incompatible with the App Sandbox, and
  changing that later would mean migrating containers. This deviation from "sandboxed where
  possible" is deliberate.
- Updates: Sparkle 2 (pinned to the commit of tag 2.10.0 in `project.yml`, not to the tag, which
  could be moved; the version is in the comment beside it, where
  `scripts/sparkle-advisories.sh` reads it) with EdDSA-signed archives. Downloads and the update feed
  (`appcast.xml`) are published on the repository's GitHub Releases by `macos/scripts/release.sh`.
  The updater starts only in builds that carry the public key; the feed needs a public repository.
- Until the Developer ID exists: local builds with the maintainer's Apple Development certificate (team ID
  in gitignored macos/Local.xcconfig). Development signing adds the debugging entitlement
  (`get-task-allow`), which would let any program running as the Owner take over the app and use
  its privacy permissions; Release builds don't inject it (`CODE_SIGN_INJECT_BASE_ENTITLEMENTS =
  NO`), and `package.sh` and `install.sh` refuse an app whose code carries it (security scan,
  2026-10-24). Debug builds keep it for the debugger.
- `install.sh` checks that an update kept the pairing (2026-10-25; on 2026-10-24 it reported
  success for an app that started "not paired"). Before quitting the old app it notes whether this
  Mac is paired: from the running app's own start line in the log (found by the process's start
  time), or, without one, from whether the pairing record exists in the Keychain (attributes
  only, no secret read). If it was paired and the new app's start line says "not paired", the
  install exits non-zero and says which versions, whether the record is still there, and not to
  pair again yet. The decision is in `install-lib.sh`, tested by
  `scripts/tests/install_pairing_test.sh` without installing anything.
- Bundle identifiers: app `net.melisma.latchkey`, helper `net.melisma.latchkey.helper` (also its
  Mach service name). Swift 6 language mode with strict concurrency.
- Debug and test builds have their own identity (FR-074; decided 2026-10-25), because macOS files
  settings, Keychain access, privacy permissions, background items, and link handlers under the
  bundle identifier. While a test copy was also `net.melisma.latchkey`, a test erased the Owner's
  pairing twice, and a leftover Debug build (which carries the debugging entitlement) could
  borrow the installed app's permissions.

  | | Release (installed) | Debug and tests |
  |---|---|---|
  | App identifier, settings domain, Keychain service, log subsystem | `net.melisma.latchkey` | `net.melisma.latchkey.dev` |
  | Helper identifier, launchd label, Mach service | `net.melisma.latchkey.helper` | `net.melisma.latchkey.dev.helper` |
  | Helper's launchd plist in the app | `net.melisma.latchkey.helper.plist` | `net.melisma.latchkey.dev.helper.plist` |
  | Link scheme registered with macOS | `latchkey` | `latchkey-dev` |
  | Data folder in Application Support | `Latchkey` | `Latchkey Dev` |
  | Name shown by macOS (permission lists) | Latchkey | Latchkey Dev |

  The Release column is exactly what shipped up to 0.8.8 and must never change: the installed
  app's pairing, activity-log key, settings, and permissions are filed under it. One mechanism,
  no duplicated files: `project.yml` sets `LATCHKEY_APP_ID`, `LATCHKEY_URL_SCHEME`, and
  `LATCHKEY_DISPLAY_NAME` per configuration; both `Info.plist` files take them by substitution,
  and a build step makes the helper's launchd plist from the one template
  (`Helper/LaunchDaemon.plist`). The code takes every name from `Shared/AppIdentity.swift`
  (chosen at compile time by the Debug flag, so nothing on disk can change which identity a
  build claims), including the code-signing requirements of D7: a Debug app and helper name
  each other's `.dev` identifiers, so the installed helper refuses a Debug app on its identifier
  as well as on its debugging entitlement. The relay's sign-in redirect stays
  `latchkey://paired` for every build: the sign-in window catches it inside the app, which
  needs no registration; a Debug build reads system-delivered links under `latchkey-dev` too.
  Files' own-files refusal (spec 003 FR-210) covers the running build's settings and data and
  the installed app's. Tests still use stand-ins for all stored data. A Debug app run by hand
  needs its own pairing, permissions, and helper approval.
- The helper's launchd plist sets `RunAtLoad`. Every helper start (at boot or on demand) first
  restores normal sleep; the app turns keep-awake back on when it connects, and re-applies when
  its XPC connection is interrupted. `SleepDisabled` is kernel runtime state (research.md), so a
  setting from a crash or power loss cannot outlive a restart, even if the app was deleted.
- Verification reads `SleepDisabled` from `IOPMrootDomain` (public, unprivileged IORegistry read).
- Install: a disk image with the app and an Applications link (`macos/scripts/package.sh`). On
  first launch outside an Applications folder the app offers to move itself there (FR-078), then
  registers the login item and the helper and opens a setup window for the two steps only the
  Owner can do.
- Uninstall: deleting the app removes the helper's launchd plist and the login item with it,
  because `SMAppService` keeps both inside the bundle. A running app also watches its bundle; when
  it lands in the Trash it disconnects (goodbye `user_disconnected`), restores sleep, unregisters
  both items, deletes the Keychain keys (device and activity log), settings, activity log, caches, and saved state, and quits
  (FR-077). If the app was quit before being deleted, its small settings file and activity log
  remain, as with most Mac apps; sleep and background items are clean either way. Replacing the
  app with a newer copy is not an uninstall: the trashed copy waits up to 5 s for a Latchkey to
  reappear at its old path (read from that path's `Info.plist`; `Bundle(path:)` caches), then
  opens it and quits. The move-to-Applications step quits a running older copy and deletes it
  rather than trashing it.
- Minimum macOS: current and previous major release, Apple silicon only (FR-075). If a required
  API needs a newer release, the floor moves up and this line says why.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/CutOffCallsTests.swift`
- `macos/Tests/InstallationTests.swift`
- `macos/Tests/OwnFilesTests.swift`
- `macos/Tests/ReleaseCheckTests.swift`
- `macos/Tests/TraceFilesTests.swift`
- `macos/Tests/UpdateGateTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

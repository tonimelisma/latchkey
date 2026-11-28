# 0176. The sandbox Mac (FR-1605, FR-1606, FR-1607, FR-1610)

- Status: accepted
- Date: 2026-11-25
- Alias: plan 016 D3 (`specs/016-test-strategy/plan.md`, "D3. The sandbox Mac (FR-1605, FR-1606, FR-1607, FR-1610)")

## Context and problem

Decision D3 of spec 016's plan (Test strategy and two ways to work); requirements in
[requirements/test-strategy.md](../requirements/test-strategy.md). Requirement IDs it cites: FR-1605, FR-1606, FR-1607, FR-1610.
The design it belongs to: [design/test-strategy.md](../design/test-strategy.md).

## Decision


- `make sandbox` in `macos/` (a local session; any Apple silicon Mac with Tart):
  1. builds the Release app from the working tree, signed with the sandbox's own self-signed
     signing identity, so every build keeps the image's permission grants. The script creates
     that identity on the Mac that runs it, the first time, in that user's login keychain under
     a sandbox-only name. Nothing personal: no `Local.xcconfig`, no Apple team or developer
     certificate, no secret, so any Apple silicon Mac with Tart runs it from any clone;
  2. starts a copy of the `latchkey-eval` image without a window (`tart run --no-graphics`), or
     reuses the one this session started (kept up until the session ends or `make sandbox-stop`);
  3. installs the build in the copy, replacing the last one (`eval-lib.sh`'s `install_latchkey`
     gets a local-build path beside the newest-release path);
  4. seeds test data (`cmd/e2e fixture`: a test folder, notes, events, reminders, contacts, a
     served sign-in page; Messages and Mail from a test account where the image has one, else
     skipped with the reason);
  5. runs `cmd/e2e sandbox`: the real MCP client through the private relay inside the copy (the
     one the image is paired with, so nothing pairs again; a proxy in front of it makes the
     network cut possible; research §6), against
     the installed app, every capability's checks plus the moved `maccheck` checks; writes `e2e-results/sandbox-<build>-<time>.json`.
  First run under 5 minutes (build ~1.5, start ~1, checks ~2); later runs reuse the copy: under
  2 minutes.
- Signing options weighed (permissions are filed under the bundle ID and the code's designated
  requirement): (a) ad hoc (`CODE_SIGN_IDENTITY=-`): a new requirement every build, the grants
  lost each time; (b) the owner's Apple Development certificate from `Local.xcconfig`: stable,
  but ties a test layer to one person's Mac, files and Apple account (in the first draft of this
  plan; decided 2026-11-26: "completely against everything we've discussed"); (c) a self-signed
  identity made for the sandbox: stable requirement (identifier plus the certificate's hash), no
  personal values. Chose (c). The image's grants are made once for that identity
  (`eval-image.sh` installs a sandbox-signed build before the person approves); evals of the
  newest release (`--release`, signed by CI) need that build's grants too, approved in the same
  sitting. To check on the first run: the keep-awake helper (`SMAppService`) with a self-signed
  signature; if macOS refuses it, the sandbox runs with keep-awake off and says so.
- Never touches the host's Latchkey, data or screen: the copy has no shared folders, no window,
  its own relay; nothing of the Mac goes in (Constitution IV, FR-1606). The build has the
  release bundle ID (so the image's grants apply) and is removed from Launch Services and
  Spotlight on the host; it is never started there.
- The same command from GitHub's Mac runner is not possible (no nested virtualization there);
  `e2e mac` stays the per-PR Mac check.
- FR-1607, first, with its regression test (done 2026-11-26): `AppLocation.needsMove` is false
  for any identity but the release one, and `offerMove` refuses to replace what is at the
  destination unless it is the same bundle ID (`mayReplace`). Options weighed: (a) rename the
  Debug product "Latchkey Dev.app" (the test host's `TEST_HOST`, `make run`, `e2e mac` and the
  CI paths all name `Latchkey.app`; wide change for the same effect); (b) the identity checks
  (two small guards, no path changes). Chose (b). Test: `InstallationTests`
  `aDevelopmentBuildNeverOffersToMoveOrReplacesTheInstalledApp` (on main the old `needsMove`
  answers yes for a Debug build in Downloads, and the replace guard doesn't exist).
- Options weighed for where (research §3): a separate macOS user (takes the screen for
  unlocked runs), a dev copy in the maintainer's account (his real data), Tart (isolated). The maintainer chose Tart.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/InstallationTests.swift`
- `scripts/tests/sandbox_test.sh`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

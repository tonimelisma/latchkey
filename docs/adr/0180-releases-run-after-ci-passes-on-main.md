# 0180. Releases run after CI passes on main

- Status: accepted
- Date: 2026-11-28

## Context and problem

The three release workflows (`mac-tag.yml`, `linux-release.yml`, `relay-image.yml`) started on a
push to main that touched their folder and ran their own copy of the checks first, in parallel
with CI. So a release could start for a commit whose CI later failed, the checks ran twice, and
each workflow's idea of "checked" could drift from CI's. The process standard releases only what
the one CI workflow passed on main.

## Decision drivers

- Nothing is published that `CI gate` didn't pass on main.
- Hosts verify the relay image's cosign identity: the workflow file `relay-image.yml` on
  `refs/heads/main`. That identity must not change.
- Merging a change that doesn't touch a part must not release that part (a relay restart, an
  update prompt on every Mac).

## Considered options

### `workflow_run` of `CI`, each release deciding from what changed since its last release

- Good: one source of "checked"; each release covers every change since the last one even when a
  queued run was replaced; the workflow files and the branch stay as they are.
- Bad: a `changes` job per workflow; the relay image needs the API to find its last published
  commit (it has no tags).
- Failure modes: if the API lookup fails, the image is published anyway (a redundant release,
  never a missed one).

### Keep push triggers, add `needs` on CI through a wait step

- Good: path filters stay.
- Bad: polling another workflow, and a race between the two.
- Failure modes: a timed-out wait drops a release.

## Decision

`workflow_run` of `CI` (completed), acting only when that run succeeded, was a push, on `main`,
in this repository; plus `repository_dispatch` and `workflow_dispatch` as before. Each workflow
checks out the commit CI tested (`workflow_run.head_sha`). Mac and Linux release when their folder
changed since the newest `mac-`/`linux-` tag on that commit's history; the relay image when
`relay/` changed since the commit of the last run whose `image` job succeeded. The workflows'
own check jobs are gone. CI's runs on main are never cancelled, so every merge reaches them.

## Consequences

Releases start a few minutes later (after CI). Signing identities are unchanged: Sparkle's EdDSA
key and the Apple certificate for the Mac, Latchkey's Ed25519 key for Linux, and cosign keyless
as `relay-image.yml@refs/heads/main` for the images.

## Confirmation

`scripts/tests/ci_tools_test.sh` (actions pinned, release jobs in their approval environments,
secrets from Key Vault); after a merge, the release runs show `workflow_run` and the summary says
what was released or why nothing was; the image's `cosign verify` step checks the identity hosts
use.

## Retirement proof

A release mechanism that publishes only CI-passed commits of main with the same signing
identities.

## Reversal plan

Restore the `push` triggers with their `paths` and the check jobs from git history; nothing else
depends on the trigger.

# 0108. Public images with every deploy (FR-911)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 009 D6 (`specs/009-easy-relay-setup/plan.md`, "D6. Public images with every deploy (FR-911)")

## Context and problem

Decision D6 of spec 009's plan (Easy relay setup); requirements in
[requirements/easy-relay-setup.md](../requirements/easy-relay-setup.md). Requirement IDs it cites: FR-911.
The design it belongs to: [design/easy-relay-setup.md](../design/easy-relay-setup.md).

## Decision


Since 2026-11-23 (cloud-first, docs/decisions.md): `.github/workflows/relay-image.yml` builds and
pushes the same two tags (the full commit hash and `latest`) after every relay change on main,
with the workflow's own token, and signs them with cosign, keyless; the hosted server updates
from the signed `latest` by itself. The two points below are the earlier way, from the Mac.

- `deploy/deploy.sh` builds linux/amd64 and linux/arm64 with `docker buildx` and pushes
  `ghcr.io/tonimelisma/latchkey-relay:<git short hash>` and `:latest`, after the security checks
  and before the server is updated (decided 2026-10-31: "with every deploy"); the server still
  gets the amd64 image as today. A push failure stops the deploy.
- The registry login uses the GitHub CLI's token (`gh auth token`), which needs the
  `write:packages` scope: a one-time `gh auth refresh -s write:packages` (the maintainer clicks Allow in
  the browser). The first push creates the package as private; it is made public once in the
  package's settings on GitHub (the maintainer's one click; unverified whether the API can do it).
- `relay/Dockerfile` already cross-compiles for the target platform.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

# 0123. Install, updates, uninstall (FR-1026, FR-1027)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 010 D12 (`specs/010-multi-host/plan.md`, "D12. Install, updates, uninstall (FR-1026, FR-1027)")

## Context and problem

Decision D12 of spec 010's plan (Several machines and Linux servers); requirements in
[requirements/multi-host.md](../requirements/multi-host.md). Requirement IDs it cites: FR-1026, FR-1027, FR-1029.
The design it belongs to: [design/multi-host.md](../design/multi-host.md).

## Decision


- **Releases**: GitHub releases tagged `server-vX.Y.Z` with `latchkey-linux-amd64`,
  `latchkey-linux-arm64`, each with `.sig` (base64 Ed25519, decided 2026-10-31, over
  `latchkey-linux-<arch> <version> <sha256>`: the version and architecture are signed too, so an
  older program can't be relabelled as newer, FR-1029) and `SHA256SUMS`. The private key lives in Azure Key Vault
  (`latchkey-server-signing-key` (the release vault), base64 seed; `SERVER_SIGNING_KEY`); the public key is in `linux/internal/update/key.go`.
  `linux/scripts/release.sh` builds, signs, and publishes. A fork sets its own key and
  `update_repo` in settings.
- **Install line** (contracts/server-program.md): `curl -fsSL https://raw.githubusercontent.com/
  tonimelisma/latchkey/main/linux/install.sh | sh -s -- https://<relay>` checks systemd, 64-bit,
  cgroup v2; downloads the newest release for the architecture and checks it against
  `SHA256SUMS` over HTTPS (the Ed25519 check needs the program itself, which then checks every
  update); runs `latchkey install`, which pairs (D7), writes the service with sudo (asking for
  the Owner's password once, interactively), and starts it.
- **Updates**: the service checks daily (and `latchkey update` at once): newest `server-v*`
  release, newer than its own version → download, verify the signature against the built-in
  key, keep the old file as `latchkey.previous`, replace, exit so systemd restarts it. The new
  version marks the update done once welcomed by the relay; not welcomed within 3 minutes (or
  crashing three times) → it puts `latchkey.previous` back and exits. A rolled-back version is
  skipped until a newer one appears.
- **Uninstall**: says goodbye `user_disconnected` (the relay revokes), stops and removes the
  service (sudo), deletes program, settings, data, cache.

## Confirmation

The tests that validate the requirements it cites:

- `linux/internal/setup/service_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

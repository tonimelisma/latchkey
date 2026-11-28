# 0030. The hosted relay's server: locked down and watched (2026-11-21)

- Status: accepted
- Date: 2026-11-21
- Alias: plan 001 D29 (`specs/001-core/plan.md`, "D29. The hosted relay's server: locked down and watched (2026-11-21)")

## Context and problem

Decision D29 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-082.
The design it belongs to: [design/core.md](../design/core.md).

## Decision


The hosted relay's key file and database are only as safe as its server, so the server is
hardened and watched by `deploy/harden.sh` (rerunnable), with the reasons and the response plan
in docs/threat-model.md, "The relay's server". In short: only 80 and 443 reach it from the
internet, SSH only through Google's IAP tunnel with OS Login (`deploy/lib.sh` `vm_ssh`, used by
every deploy); the relay shares a Docker network with Caddy alone, so FR-082's trusted proxies are
Caddy only; the VM's own least-privilege service account, Secure Boot, automatic updates with a
nightly reboot when needed; unneeded packages and services removed. Intrusion detection reports
off the server to Cloud Logging and emails the owner: the sentinel
(`deploy/server/host/sentinel.py`, standard library Python, tested by
`deploy/tests/test_sentinel.py`) on audit events, SSH and sudo, Docker, ports, processes and
packages; cloud audit-log alerts; a heartbeat and an uptime check (`deploy/alerts.py`). Options
weighed: CrowdSec and Falco (too much memory for 1 GB, and largely covered), AIDE (noisy after
every package update; `dpkg --verify` checks programs against their packages instead), the
Ops Agent (about 150 MB; the sentinel writes to the Logging API itself).

## Confirmation

The tests that validate the requirements it cites:

- `relay/internal/account/account_test.go`
- `relay/internal/server/alerts_test.go`
- `relay/internal/server/guard_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

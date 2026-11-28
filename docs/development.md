# Developing Latchkey

Latchkey is in testing (version 0.8): every capability is built and checked live on a real Mac.
Every installed version is also the public download (GitHub release `mac-<x.y.z>`, asset
`Latchkey.dmg`; `macos/scripts/publish.sh`, run by CI's Mac release job and by
`make -C macos install`), with Sparkle's update archive and feed (spec 001 FR-072). It is signed for
development, not notarized, so a downloaded copy opens after System Settings → Privacy &
Security → Open Anyway, once per version. The relay's image is published
at `ghcr.io/tonimelisma/latchkey-relay` ([self-hosting.md](self-hosting.md)). Open work: GitHub issues; the record so far: [STATUS.md](STATUS.md).
How the product works: [how-it-works.md](how-it-works.md).


| Part | Where | Commands |
|---|---|---|
| Relay (Go) | `relay/` | `make test`, `make lint`, `make run`, `make security`, `make script-tests` |
| Linux server program (Go) | `linux/` | `make test`, `make lint`, `make test-linux` (every test on Debian with systemd in Docker), `make check` (end to end: relay, pretend Mac, the program installed in a container, a real MCP client); releases by `.github/workflows/linux-release.yml` |
| Mac app and helper (Swift) | `macos/` | `make test`, `make lint`, `make run`, `make dmg`, `make install` (CI's newest release tag: build, install into Applications, start, and fail if the update lost the pairing; the Mac's updater runs it for each new tag), `macos/scripts/readme-shots.sh` (redraws the app's pictures in docs/images) |
| End-to-end tests and evals (spec 015) | `relay/cmd/e2e`, `relay/e2e/`, `.github/workflows/e2e.yml` | every pull request: the changed capabilities checked with a real MCP client through a private relay on GitHub's Linux and Mac runners,; in a local session on an Apple silicon Mac with Tart (spec 016): `macos/scripts/eval-image.sh` once, then `make -C macos sandbox` after every Mac build (the local build in a Tart virtual Mac, every capability with test data) and `make -C macos evals` when tools change (real Claude Code, about 20 tasks 3 times each); results in `e2e-results/` |
| Relay image | `.github/workflows/relay-image.yml` | publishes and signs `ghcr.io/tonimelisma/latchkey-relay` on every relay change on main; hosts that verify the signature pull it (the hosted relay's server is run outside this repository) |

## How this repo is organized

Work starts as research and requirements and flows downward; code is the last step, not the
first (CLAUDE.md, "Where docs live"). `docs/index.md` maps every doc.

```
CLAUDE.md                       Instructions for every session (AGENTS.md is a link to it).
docs/requirements/<area>.md     What each capability does: EARS requirements with stable IDs.
docs/design/<area>.md           How each part is built (GOVERNS: its code); contracts/ for protocols.
docs/adr/                       One record per decision; 0001 is the constitution.
docs/research/                  Dated research behind the designs.
relay/                          The relay (Go). `make test`, `make run`.
macos/                          The Mac app and its helper (Swift, XcodeGen). `make test`, `make run`.
linux/                          The Linux server program (Go). `make test`, `make test-linux`.
script/                         The process scripts (process-check, pr-check, stage, verify).
scripts/                        Release, cleanup and session-setup scripts and their tests.
SECURITY.md                     How to report vulnerabilities.
```

Personal deployment details (the hosted relay's address, server, signing team) live only in
gitignored files: `.env` and macos/Config/Local.xcconfig. Latchkey's tools and the relay read
their secrets from Azure Key Vault when they run (below), never from a file in the repository.

## Maintainer setup

One-time steps for whoever runs the releases; the vault, tenant and identity details live in the
private repositories that manage them, not here.

- Release secrets live in an Azure Key Vault, not in GitHub. The release jobs of
  `linux-release.yml` and `mac-tag.yml` fetch them in their first step with the job's GitHub
  identity token (OIDC; no stored credential). The environment `release` holds only the
  variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_KEY_VAULT`, for an Entra app that
  trusts only this repository's environment `release`. Environment name = vault secret:
  `SERVER_SIGNING_KEY` = `latchkey-server-signing-key`; `MAC_CERTIFICATE_P12` =
  `apple-development-p12-base64` (the "Apple Development" certificate with its key, exported
  from Keychain Access, base64), `MAC_CERTIFICATE_PASSWORD` = `apple-development-p12-password`,
  `MAC_DEVELOPMENT_TEAM` = `apple-development-team`, `SPARKLE_PRIVATE_KEY` =
  `latchkey-sparkle-private-key` (Sparkle's `generate_keys -x`), whose public key goes into
  `SPARKLE_PUBLIC_ED_KEY` in `macos/Config/Base.xcconfig` (public; committed).
- Every other consumer reads its secrets from Key Vault itself when it runs; an environment
  variable of the same name wins when set (`relay/internal/keyvault`). The code holds no tenant,
  app or vault: the environment names them, and a missing one stops the tool with an error that
  names the variable (never a value).

  | Variable | Used by | What it is |
  |---|---|---|
  | `AZURE_TENANT_ID` | every sign-in | the Entra tenant |
  | `AZURE_CLIENT_ID` | the client secret and the VM's identity (not `az login`) | the Entra app that signs in |
  | `MELISMA_SECRETS_CLIENT_SECRET` | cloud sessions | that app's client secret; when set, it is the sign-in |
  | `LATCHKEY_KEYVAULT_AUTH=gce` | a relay on a Google VM | sign in as `AZURE_CLIENT_ID` with the VM's identity token |
  | `LATCHKEY_KEYVAULT_HOSTS` | the relay | the vault with `resend-api-key` (its `SMTP_PASSWORD`) |
  | `LATCHKEY_KEYVAULT_DEV` | `latchkey-reports` | the vault with `latchkey-intake-developer-token` |
  | `LATCHKEY_KEYVAULT_RELEASE` | `latchkey-reports`, `evals --send` | the vault with `latchkey-reports-private-key` |

  With neither the client secret nor `gce`, the sign-in is the Azure CLI's (`az login`). On a
  Mac, export `AZURE_TENANT_ID`, `LATCHKEY_KEYVAULT_DEV` and `LATCHKEY_KEYVAULT_RELEASE` in the
  shell's profile (for example `~/.zshenv`) before running `latchkey-reports` or
  `make -C macos evals ARGS=--send`; a local `make release` in `linux/` reads
  `SERVER_SIGNING_KEY` from the vault `AZURE_KEY_VAULT` names. Cloud sessions sign in with the
  client secret their environment holds (`docs/cloud-sessions.md`). The hosted relay, with
  `SMTP_USER` set and no `SMTP_PASSWORD`, reads its email key at startup, signing in with its
  VM's identity; its `relay.env` (`AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `LATCHKEY_KEYVAULT_HOSTS`,
  `LATCHKEY_KEYVAULT_AUTH=gce`) lives in the repository that runs that server.
- ghcr.io packages `latchkey-relay` and `latchkey-intake`: Package settings → Manage Actions
  access → this repository with Write (so the image workflow can publish them).
- Optional: required reviewers on the environments `release` and `production`; a tag ruleset so
  only GitHub Actions creates `mac-*` and `linux-*` tags.

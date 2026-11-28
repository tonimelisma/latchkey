# 0162. The developer's agent (FR-1430, FR-1431)

- Status: accepted
- Date: 2026-11-23
- Alias: plan 014 D5 (`specs/014-feedback-intake/plan.md`, "D5. The developer's agent (FR-1430, FR-1431)")

## Context and problem

Decision D5 of spec 014's plan (Problem reports to the developer); requirements in
[requirements/feedback-intake.md](../requirements/feedback-intake.md). Requirement IDs it cites: FR-1430, FR-1431.
The design it belongs to: [design/feedback-intake.md](../design/feedback-intake.md).

## Decision


- The token and the private key (since 2026-11-26; before, a network secret and a variable of
  the maintainer's personal cloud environment): in Azure Key Vault (`latchkey-intake-developer-token` (the dev vault),
  `latchkey-reports-private-key` (the release vault)), which `latchkey-reports` reads itself when
  `LATCHKEY_INTAKE_TOKEN` and `LATCHKEY_REPORTS_KEY` aren't set (since 2026-11-27, replacing the
  session-start fetch of 2026-11-26): with the cloud session's `MELISMA_SECRETS_CLIENT_SECRET`, or
  `az login` on the Mac (`relay/internal/keyvault`; `docs/cloud-sessions.md`, "The environment"). `latchkey-reports list` (`relay/cmd/latchkey-reports`)
  fetches the open reports and prints them opened, only inside the session; `latchkey-reports
  delete <id>` deletes a dispositioned one.
- `docs/cloud-sessions.md` and CLAUDE.md's session start change from "list the Mac's Feedback
  folder" to "count open reports at the intake".

## Confirmation

The tests that validate the requirements it cites:

- `relay/cmd/latchkey-reports/show_test.go`
- `relay/reports/reports_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

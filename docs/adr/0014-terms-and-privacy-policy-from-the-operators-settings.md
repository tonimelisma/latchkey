# 0014. Terms and privacy policy, from the operator's settings

- Status: accepted
- Date: 2026-10-24
- Alias: plan 001 D13 (`specs/001-core/plan.md`, "D13. Terms and privacy policy, from the operator's settings")

## Context and problem

Decision D13 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-193, FR-194.
The design it belongs to: [design/core.md](../design/core.md).

## Decision

Serves FR-193, FR-194; Constitution V, VI.
- Settings `OPERATOR_NAME` and `OPERATOR_CONTACT` (both or neither; the contact must be one
  plain email address), and optional `OPERATOR_LAW`, `OPERATOR_PROVIDERS`, `BACKUP_DAYS`. With
  the two set, `/terms` and `/privacy` are served from `html/template` files, with the pages'
  style and headers and no script; the footer of every page links them; the email step of the
  sign-in page says "By continuing, you agree to the Terms and the Privacy Policy"; and the
  authorization-server metadata carries `op_tos_uri` and `op_policy_uri`. Without them the two
  paths are 404 and nothing links to them.
- The texts describe "this relay" and say only what the code does. Each shows its effective
  date, a constant beside the template that changes with the text. A test renders the policy
  and requires a phrase for every table in `docs/design/data-model.md` and in the database, so the policy
  can't fall behind what is stored; another fails on any address, name, or place written into
  the templates.

## Confirmation

The tests that validate the requirements it cites:

- `relay/cmd/relay/config_test.go`
- `relay/internal/account/legal_test.go`
- `relay/internal/server/legal_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

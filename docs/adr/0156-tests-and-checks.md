# 0156. Tests and checks

- Status: accepted
- Date: 2026-11-21
- Alias: plan 013 D9 (`specs/013-sign-in/plan.md`, "D9. Tests and checks")

## Context and problem

Decision D9 of spec 013's plan (Signing in); requirements in
[requirements/sign-in.md](../requirements/sign-in.md). Requirement IDs it cites: none current.
The design it belongs to: [design/sign-in.md](../design/sign-in.md).

## Decision


- Unit: `SignInDataTests` (CSV, codes with RFC 6238's vectors, site matching), `SignInStoreTests`
  (replace all or nothing, failures, memory vault), `SignInPageTests` (the real WebKit view with
  fixture pages at an https address: one-page and two-page forms, a code step, a frame from
  another site, a page of another site, a refused password, fields cleared, no secret in any
  answer), `SignInToolsTests` (the tools: Off means gone, list, no sign-in, several users,
  second failure blocks), `PublicToolsTests` (27 tools), `ReadmeTests`.
- Export: the first real export is the maintainer's click on Export Passwords to Latchkey… in the menu
  (his Touch ID); Claude then checks the log shows the file taken in and deleted.
- Live (screen-state cases, group `logins`): with a test sign-in for the public test site
  the-internet.herokuapp.com dropped into the import folder (only while Latchkey holds no
  sign-ins of the Owner's, so nothing of his is replaced; removed in teardown), a fresh Claude
  lists the site, signs in, and the traces are searched for the password.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

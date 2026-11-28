# 0113. Tool list: union with per-kind notes (FR-1003, FR-1004, FR-1007; decided 2026-10-31)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 010 D2 (`specs/010-multi-host/plan.md`, "D2. Tool list: union with per-kind notes (FR-1003, FR-1004, FR-1007; decided 2026-10-31)")

## Context and problem

Decision D2 of spec 010's plan (Several machines and Linux servers); requirements in
[requirements/multi-host.md](../requirements/multi-host.md). Requirement IDs it cites: FR-1003, FR-1004, FR-1007.
The design it belongs to: [design/multi-host.md](../design/multi-host.md).

## Decision


`mcpserver` builds the Owner's list from every active device's stored tools:

- A name offered by one kind only, with one definition: that definition.
- Otherwise, per kind present (Mac first, then Linux), the definition from that kind's most
  recently seen device. Description: "On a Mac: …" and "On a Linux server: …" paragraphs (one
  paragraph when only one kind offers it but versions differ: the newest). `inputSchema`: the
  union of properties; a property only some kinds have gets " (Mac only)" or " (Linux servers
  only)" appended to its description; enum values are united, required is the intersection.
  Annotations: read-only and idempotent only if all are, destructive and open-world if any is.
  Deadline: the largest. `outputSchema` only if all are equal.
- Every machine tool gets the property `machine` (string): "The machine to use, by name, as
  the machines tool lists it. Leave it out when only one machine offers this tool." Agents may
  not define `machine` themselves (protocol violation, D3).
- The relay's own tool `machines` (read-only) is listed while the account has at least one
  paired machine. `laptop_status` stays reserved.

Options weighed in research.md; tool-per-machine and a `machine` enum were rejected because
Claude's apps cache the list.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

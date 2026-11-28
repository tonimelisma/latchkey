# Test strategy and two ways to work: requirements

Spec 016 (migrated from `specs/016-test-strategy/spec.md`, titled "Spec 016: Test strategy and two ways to work — WHAT and WHY"). The how is in
[the design](../design/test-strategy.md), each decision in [the ADRs](../adr/README.md) of plan 016.
Each requirement is one `- **ID**` item ending `[verified]` (a test carries
`Validates: <ID>`) or `unverified: <why>`. Withdrawn requirements are kept, undeclared, at
the end as the record. Some items still carry dated notes of how they came to be; the
requirement is the sentence they qualify.

Status: choices made on 2026-11-26 (below); plan in `docs/design/test-strategy.md`, for his review before
tasks. Research, the inventory and sources: `docs/research/2026-11-25-test-strategy.md`.

## Problem

decided 2026-11-26: "you don't really have a proper test strategy here ... it's a bit of a
hodgepodge of different tests. some outside of sandbox, some inside, overlaps ... let's
streamline as much as possible. speed is essential, but it needs to be ecologically valid."

The inventory (`docs/research/2026-11-25-test-strategy.md` §1) shows it: the same setup is built in seven harnesses, files,
shell and the own browser are checked three or four times while Notes, Calendar, Messages and
the rest are checked only against stand-ins; nothing that runs today uses real macOS permissions
or a built app; the Mac's tests don't gate merging; every check with real Claude, real
permissions or a real screen state depends on someone running it by hand, and none has run.

Development also runs two ways now (decided 2026-11-26: "dual process, depending on where the
session runs"): cloud sessions first, with no Mac; and sessions the maintainer starts in Claude Code on
his Mac, which do have one and should use it: "if you've built something, you should run tests
if you're local and thus have access to the mac."

## The maintainer's choices (2026-11-26)

- Two ways to work. A cloud session has no Mac: it never uses Latchkey to reach the developer's own Mac
  while developing (building, testing, starting the updater), except a live check the maintainer asks for
  in that session ("Allowed when I ask"). A local session is Claude Code started on the Mac, and
  runs on the Mac whatever the change needs.
- Both ways are described in CLAUDE.md itself ("All in CLAUDE.md").
- The sandbox Mac is a Tart virtual Mac running the local build ("Virtual Mac (Tart)").
- The Mac app's tests block merging, once the tests that measure real time use fake clocks
  ("Yes, block merges").
- The hand-run kits that don't run (screen-state cases on his Mac, `claude-check`, `mac-check`,
  `guidecheck`, `safari-check`) are retired and what they cover folded into the sandbox Mac and
  the eval tasks; a fixed bug's test goes in the lowest layer that reproduces it ("Retire and
  fold in").
- CLAUDE.md trimmed under ~200 lines with every rule kept, and rule changes proposed to the maintainer one
  by one ("Trim and rethink rules").

## Proposed layers (each fake checked by a real layer above it)

| Layer | Proves | Real / stand-in | Runs | When | Budget |
|---|---|---|---|---|---|
| 1. Fast | logic, parsers, deadlines, the protocol's golden messages, tool snapshots | stand-ins, fake clocks | cloud, local, CI | every change; gates merging | < 5 min per area |
| 2. Integration | relay as a real MCP server with a real client; the Linux program installed; the app's tool code over a real relay | real processes on one machine; pretend far side | CI (GitHub Linux and Mac), local | every PR, by changed paths; gates merging | < 5 min |
| 3. Sandbox Mac | the built app starts, pairs, gets its permissions, and every capability works against the real Mac apps with test data | everything real except the data and the relay (a private one) | local session: after every Mac build; anyone by hand | after building | first run < 5 min, then < 2 min |
| 4. Evals | Claude can do real tasks with the tools | real Claude, real tools, sandbox Mac | local session or by hand | when tools or their descriptions change, on a new model | reported as rates, never a gate |
| 5. the requester's conditions | locked, lid closed, his real accounts and sites | everything real | The maintainer's Mac | when the maintainer runs or asks for it; and evidence recorded during real use | — |

### Requirements (EARS; IDs stable)

- **FR-1601** When a change is pushed, CI shall run the fast and integration layers for the
  changed areas, and a failure in either shall block the merge. unverified: no test cites it yet (migrated from spec 016 without one; #75)
- **FR-1602** Tests shall not assert on wall-clock time; time-dependent logic shall run on a
  fake clock, so the fast layer passes on GitHub's runners as on the Mac. [verified]
- **FR-1603** One end-to-end harness (`relay/cmd/e2e`) shall build the private relay, sign-up
  and pairing used by every end-to-end check; the other harnesses are folded into it or removed
  (`docs/research/2026-11-25-test-strategy.md` §1, finding 4). unverified: no test cites it yet (migrated from spec 016 without one; #75)
- **FR-1604** Each behavior shall be pinned in one layer: a capability turned off in the
  integration layer only. Tool descriptions are not pinned by any test (2026-11-26: the
  snapshots were removed, decided: "That's a stupid check. Remove it"). unverified: no test cites it yet (migrated from spec 016 without one; #75)
- **FR-1605** When a local session has built the Mac app, it shall run the sandbox Mac layer on
  that build before calling the change done, and quote the result with the build, the time and
  what was seen. [verified]
- **FR-1606** The sandbox Mac shall never read or change the maintainer's real data or accounts, never
  touch the installed Latchkey, and never take the screen, pointer or keyboard while he may be
  using the Mac (Constitution IV). It runs in a Tart virtual Mac with the local build installed
  (decided 2026-11-26). [verified]
- **FR-1607** A development build shall never offer to move itself into Applications, and a
  move shall never replace an app with another bundle identifier (the installed
  `/Applications/Latchkey.app` included) (bug found 2026-11-26, `docs/research/2026-11-25-test-strategy.md` §3). [verified]
- **FR-1608** Evals shall run in the sandbox Mac against the local build or the newest release,
  be scored on the end state, and be reported as pass rates; they never block a merge. unverified: no test cites it yet (migrated from spec 016 without one; #75)
- **FR-1609** A fixed bug's regression test shall live in the lowest layer that reproduces it
  (fast, integration, or sandbox Mac), and run automatically in that layer. The screen-state
  kit (macos/scripts/state-check/) and the other hand-run kits are retired; their cases move
  into the sandbox Mac checks and the eval tasks (decided 2026-11-26). unverified: no test cites it yet (migrated from spec 016 without one; #75)
- **FR-1610** The same command shall run a layer in a cloud session, a local session, and CI
  (`make test`, `make e2e`, `make sandbox`). unverified: no test cites it yet (migrated from spec 016 without one; #75)
- **FR-1611** A row in the requester's conditions (locked, lid closed, his accounts) shall stay NOT
  VERIFIED until it was seen in that condition on his Mac (CLAUDE.md, "Done means the maintainer's
  conditions"); sandbox results are evidence only for the conditions the sandbox really has. unverified: no test cites it yet (migrated from spec 016 without one; #75)

- **FR-1612** All testing of a commit, local and CI together, shall finish within 5 minutes of
  the moment the developer's work is ready (the push, or the local run's start); where a layer
  can't, the reason is measured and reported to the maintainer (decided 2026-11-26: "each commit wraps up in
  5 minutes of testing from the moment dev works ... local and CI together, everything").
  Measured and reported 2026-11-26 (research §5): a Mac change ~5.5 min when a macOS machine is
  free; the maintainer kept four Mac jobs ("Keep 4 jobs, ~5.5 min") over five jobs or paid runners.
  The sandbox's full run takes about 7 minutes (research §7); the maintainer chose the full run after every
  Mac build over a quick subset ("Always the full run", 2026-11-27). unverified: no test cites it yet (migrated from spec 016 without one; #75)

## Success criteria

- A pull request's checks finish within 5 minutes of the push (FR-1612) and are green on main.
- Every capability is exercised against the real Mac app it uses, with test data, at least in
  the sandbox Mac, with no stand-in left unchecked by a real layer.
- A local session that builds the Mac app ends with a quoted sandbox run of that build.
- No test touches the maintainer's real data, the installed app, or his screen.

## Out of scope

The lid closed and the maintainer's real accounts in any automated layer; a weekly or scheduled run
(decided 2026-11-25).

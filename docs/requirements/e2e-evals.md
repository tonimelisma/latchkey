# End-to-end tests and evals: requirements

Spec 015 (migrated from `specs/015-e2e-evals/spec.md`, titled "Spec 015: End-to-end tests and evals — WHAT and WHY"). The how is in
[the design](../design/e2e-evals.md), each decision in [the ADRs](../adr/README.md) of plan 015.
Each requirement is one `- **ID**` item ending `[verified]` (a test carries
`Validates: <ID>`) or `unverified: <why>`. Withdrawn requirements are kept, undeclared, at
the end as the record. Some items still carry dated notes of how they came to be; the
requirement is the sentence they qualify.

Status: Approved by the maintainer (2026-11-24: "sounds liek a great plan. build it uflly"); tasks spec 015's task list (in git history; open items are GitHub issues).
Research, sources and the options weighed: `docs/research/2026-11-24-e2e-evals.md`. How: `docs/design/e2e-evals.md`.

## Problem

Latchkey is checked today by unit tests (relay, Linux program, Mac app on GitHub's Mac runner),
by a few Go checks that run real Claude Code through a private relay (`localcheck`,
`linuxcheck`, `guidecheck`, `maccheck`), and by written regression cases
(macos/scripts/state-check/cases.json) that nothing runs. The live test sessions against
the maintainer's real Mac were removed on 2026-11-23: they touched his real data and needed his approvals.
So nothing checks, after a change, that Claude can still do real work with Latchkey's tools end
to end, and every "does it work" ends in reasoning or a unit test, which CLAUDE.md ("Done means
the requester's conditions") says verifies nothing.

## The maintainer's choices (2026-11-24)

- Two places: GitHub's macOS (and Linux) runners per pull request, and a throwaway virtual Mac
  on the maintainer's Mac "definitely not nightly. maybe weekly. targeted e2e tests for features that have
  changed in each PR".
- Claude runs on the maintainer's Claude subscription (a `claude setup-token` token as a repository
  secret), never API credits.
- "latchkey should not be a blocker for any PR. it requires manual approvals. latchkey asks
  should be minimized, and batched together".
- The harness extends the repository's own Go checks; no outside eval framework.
- Claude-driven tasks only in the weekly run; per pull request, scripted checks only.
- The per-pull-request end-to-end checks are reported on the pull request, not required for
  merging (decided 2026-11-25: "I don't want the checks required"; replaces "All block",
  2026-11-24).
- The weekly run is started by the maintainer by hand: "prompt to run it manually if not run that week".
- Weekly results go, encrypted to the developer's key, to the developer's intake (spec 014).
- The Mac tests run from the repository: anyone who clones it can run them from their own Mac
  (decided 2026-11-24). "if someone is running tests, they are a developer, so the results should
  stay local for their dev agent": results stay in their copy unless they ask to send them.
- Every tool's name, description and inputs are snapshotted; a change fails until the snapshot
  is updated in the same commit.
- The weekly set: about 20 tasks, 3 tries each, capped at one hour.
- A release counts as checked once its pull request's checks passed; the next weekly run
  reports on it; releases never wait for the weekly run.

## Parties

- **The developer's agent**: a Claude Code cloud session working on Latchkey.
- **The maintainer**: the owner; the only one who can run anything on his Mac.
- **GitHub's runners**: throwaway Linux and macOS machines, no access to the maintainer's data.
- **The test Mac**: a virtual Mac on the maintainer's Mac, copied fresh from a prepared image for each run,
  holding only test data.

## User stories

### US1 (P1): A pull request shows that the changed features still work end to end
1. Given a pull request changes files of a capability, then GitHub runs that capability's
   end-to-end checks with a real MCP client through a private relay, and the pull request can't
   merge until they pass.
2. Given a pull request changes no capability, then those checks pass at once without running.
3. Given a pull request changes what Claude sees of a tool and doesn't update the snapshot,
   then it fails, naming the tool.
4. Nothing in a pull request's checks reaches the maintainer's Mac, his data, or his approvals.

### US2 (P1): Once a week, real Claude does real tasks on a test Mac, from any clone
1. Given no weekly run this week, when a cloud session starts, then it tells the maintainer in one line
   what to run, a single action on his Mac.
2. Given the maintainer starts it, then it runs with no further approval or question, on a fresh copy of
   the test Mac, with test data only, and leaves nothing behind on his Mac.
3. Given it finishes, then its results reach the developer's intake, and the next cloud
   session reads them without touching the maintainer's Mac.

### US3 (P1): A result is judged by what happened, not by Claude's words
1. Given a task ends, then it passes only if the test Mac's state (the note, the file, the
   reminder, the page's record) matches the goal, and no forbidden tool call was made.
2. Given a task passes only some of its tries, then the report says so, as a flaky task.

### US4 (P2): Planted instructions in test data don't steer Claude into harm
1. Given test content holds an instruction to do something the owner didn't ask (send a
   message, read a password, delete files), then the task checks the owner's goal was met and
   the planted action did not happen.

### US5 (P2): "Done means the requester's conditions" rows stay honest
1. Given a row needs a state only the maintainer's real Mac has (locked, lid closed, real iMessage, a real
   site), then no test here marks it VERIFIED; the reports say which rows they can't
   reach.

## Requirements

### Per pull request (GitHub)
- **FR-1500** When a pull request is opened or updated, the system shall decide from the files
  it changes which capabilities are affected, with one map from paths to capabilities kept in
  the repository; a change to shared parts (the relay's MCP surface, the agent protocol, the
  Mac app's core) shall select every capability. unverified: no test cites it yet (migrated from spec 015 without one; #75)
- **FR-1501** For each affected capability, the system shall run its end-to-end checks: a real
  MCP client with a real OAuth token, through a private relay started for the run, calling the
  capability's tools on a real machine (the real Mac app on GitHub's macOS runner, the real
  Linux program in its container), and checking the outcome on that machine's state. [verified]
- **FR-1502** Each end-to-end check shall report its result on the pull request without being
  required for merging (decided 2026-11-25; was "All block", 2026-11-24); when no capability is
  affected it shall pass without running. unverified: no test cites it yet (migrated from spec 015 without one; #75)
- **FR-1503** The per-pull-request checks shall not run Claude, shall use no Claude
  subscription, and shall never reach the maintainer's Mac, his accounts, or Latchkey on his Mac. unverified: no test cites it yet (migrated from spec 015 without one; #75)
- **FR-1505** Web pages a check uses shall be served by the check itself (local test pages,
  local sign-in forms, local downloads); no check shall reach a real site. unverified: no test cites it yet (migrated from spec 015 without one; #75)
- **FR-1506** A check that can't run on a runner (a permission GitHub's runner can't grant, a
  screen state it has no) shall be listed as skipped with the reason, never counted as passed. unverified: no test cites it yet (migrated from spec 015 without one; #75)

### The test Mac run (by hand only; no longer weekly)

Amended 2026-11-25 (decided: "Drop it, keep per-PR checks"): there is no weekly run and no reminder.
The test Mac's scripts stay in the repository; whoever wants a run starts it by hand. "Weekly run"
below means such a run.
- **FR-1510** The weekly run shall be started by hand with a single command from a clone of the
  repository, on any Apple silicon Mac (decided 2026-11-24: anyone with the repository can run
  it). It shall ask nothing further and need no Latchkey approval. unverified: no test cites it yet (migrated from spec 015 without one; #75)
- **FR-1512** Each run shall use a fresh copy of a prepared test Mac image that holds only test
  data and Latchkey's permissions approved once; the copy shall be deleted at the end, pass or
  fail, and nothing of the run shall stay on the maintainer's Mac except the prepared image. unverified: no test cites it yet (migrated from spec 015 without one; #75)
- **FR-1513** Preparing the image shall be a one-time step, run from the repository by whoever
  runs the tests, done again only when its
  permissions are lost (a new macOS, or Latchkey's signature changing); the run shall say so
  plainly when a permission is missing instead of failing tasks one by one. unverified: no test cites it yet (migrated from spec 015 without one; #75)
- **FR-1514** The run shall never touch the user's own session: no window brought to the front, no
  pointer or keystrokes in his apps, no read of his data (Constitution IV); the test Mac runs
  without a window on his screen. unverified: no test cites it yet (migrated from spec 015 without one; #75)
- **FR-1515** The run shall have Claude Code, on the maintainer's subscription, do about 20 tasks, each 3
  times on a fresh start state, on Sonnet, the whole run capped at one hour; tasks not reached
  by the cap shall be reported as not run. [verified]
- **FR-1516** The run shall also run every capability's end-to-end checks (FR-1501) on the test
  Mac, including those skipped on GitHub's runner for a permission (FR-1506). unverified: no test cites it yet (migrated from spec 015 without one; #75)
- **FR-1517** The run shall never gate a pull request or a release (decided 2026-11-24). unverified: no test cites it yet (migrated from spec 015 without one; #75)

### Tasks and scoring
- **FR-1520** A task shall be written as: an instruction to Claude in the owner's words, a
  start state (test data put in place before), a check of the end state, the tool calls that
  are required, forbidden, or unneeded, and the cleanup. unverified: no test cites it yet (migrated from spec 015 without one; #75)
- **FR-1521** A task shall pass only when its end-state check passes and no forbidden tool call
  was made; Claude's own words shall never count toward passing. [verified]
- **FR-1522** For each task the report shall give the passes out of the tries, whether all
  tries passed (pass^3) and whether any did (pass@1), and for each try the tool calls made,
  tool errors, turns, and tokens. unverified: no test cites it yet (migrated from spec 015 without one; #75)
- **FR-1523** A run shall fail as a whole, before any task, if Claude Code didn't load Latchkey
  as its only MCP server or Latchkey's tools aren't listed. [verified]
- **FR-1524** Some tasks shall hold planted instructions in their test data (a note, a page, a
  file, a message) and shall check both that the owner's goal was met and that the planted
  action did not happen. [verified]
- **FR-1525** Every regression case in `cases.json` that needs real Claude or the test Mac shall
  be able to run as a task; the task set shall say which cases it covers. (Spec 016, 2026-11-26:
  `cases.json` is retired; the cases are the rows of `docs/regression-coverage.md`.) [verified]
- **FR-1526** A held-out part of the tasks shall be kept so that tool descriptions aren't tuned
  to the tasks themselves; reports shall give its score separately. [verified]

### Results
- **FR-1530** The weekly results shall always be written to a file in the clone the run started
  from (outside version control) and summed up in Terminal. Only when the person running it asks
  (an option on the command) shall they also go to the developer's intake (spec 014), encrypted
  to the developer's key, as their own kind of entry, apart from problem reports; nothing in them
  shall hold anyone's own data (the test Mac has none). unverified: no test cites it yet (migrated from spec 015 without one; #75)
- **FR-1530a** A developer's agent working in the same clone shall be able to read the local
  results file directly; the maintainer's cloud sessions read the sent ones (FR-1531). unverified: no test cites it yet (migrated from spec 015 without one; #75)
- **FR-1531** A cloud session shall list and read the weekly results with the developer's
  command, as it reads problem reports, and compare them with the previous week's: new
  failures, fixed tasks, flaky tasks. unverified: no test cites it yet (migrated from spec 015 without one; #75)
- **FR-1532** Each new failure found by a run shall become an issue found (CLAUDE.md, "Every
  issue becomes a regression case"): fixed with its regression test, or reported to the maintainer. unverified: no test cites it yet (migrated from spec 015 without one; #75)
- **FR-1533** Results shall be deleted from the intake once a session has read and
  dispositioned them, as problem reports are (spec 014 FR-1424). unverified: no test cites it yet (migrated from spec 015 without one; #75)

### Releases and the requester's conditions
- **FR-1540** A release shall count as checked when its pull request's end-to-end checks
  passed (FR-1502); one merged with a failing check counts as not checked, and the session that
  merged it says so; a test Mac run, when someone starts one, shall report the release it ran on; no
  release shall wait for one (decided 2026-11-24; amended 2026-11-25: no weekly run). unverified: no test cites it yet (migrated from spec 015 without one; #75)
- **FR-1541** A row of "Done means the requester's conditions" that needs the maintainer's real Mac (locked, lid
  closed, real iMessage, a real site, his own accounts) shall stay NOT VERIFIED whatever these
  tests show; a weekly result may be quoted as evidence only for a row whose condition the test
  Mac really has, with version, time, and the state seen. unverified: no test cites it yet (migrated from spec 015 without one; #75)

## Out of scope

- Runs against the maintainer's real Mac, his accounts, or real sites (decided 2026-11-23).
- The lid closed, the real lock screen, real iMessage and iCloud, real sites: not
  reproducible outside the maintainer's Mac (`docs/research/2026-11-24-e2e-evals.md`).
- An LLM judge as the score (unreliable; `docs/research/2026-11-24-e2e-evals.md`).
- Nightly runs (decided 2026-11-24).


## Withdrawn requirements (record)

Not current behavior; kept so the IDs and their reasons stay findable.

- FR-1504: (withdrawn 2026-11-26: "That's a stupid check. Remove it"; no tool
  snapshots are kept or compared) The system shall keep in the repository a snapshot of every tool's name,
  description and input schema as Claude sees it, per machine kind; when the tools differ from
  the snapshot, the check shall fail naming each tool that changed, until the snapshot is
  updated in the same pull request. A changed snapshot shall select that tool's capability
  (FR-1500).
- FR-1511: (Withdrawn 2026-11-25: no reminder; the maintainer, "Drop it, keep per-PR checks". Was:) When a cloud session starts and no weekly result has arrived in the current week
  (Monday to Sunday, the maintainer's time zone), the session shall tell the maintainer in one line that the weekly
  run is due and the single command that starts it (with the option that sends the results to
  the intake).

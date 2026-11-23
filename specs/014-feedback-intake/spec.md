# Spec 014: Problem reports to Latchkey's developer — WHAT and WHY

Status: Draft for Toni's review (2026-11-23). No code yet. Replaces spec 001 FR-691 to FR-693
once built (the relay keeping reports, delivering them to the Mac, the Mac's Feedback folder).
Research and the options weighed: `research.md`. How: `plan.md`.

## Problem

Claude files a report with the `feedback` tool whenever something done with Latchkey didn't
fully work (spec 001 FR-690). On 2026-11-23, 172 reports had piled up in Toni's Mac's Feedback
folder. Reading them took Latchkey shell calls on the Mac, each needing approval and cut off at
50 KB; marking them handled was impossible from Claude (Latchkey's shell can't write in
Latchkey's own folder, and macOS refuses a script Latchkey opens in Terminal); they held
verification codes, phone digits and account numbers in plain text; and they only ever reached
Toni because he is a user too. Other users' reports never reach the developer.

## Parties

- **A user**: their Claude chats, their machines, their account on a relay.
- **A relay operator**: anyone; often the user. Carries every Latchkey call for its accounts.
- **The developer** (Toni for Latchkey; a fork's own developer otherwise): owns the intake and
  the development agent. Has no access to any relay, and sees a user's report only when that
  user chose to share.

## User stories

### US1 (P1): I choose whether my problem reports go to the developer
1. Given a new install, then sharing is Off, and Claude sees no `feedback` tool and is never
   asked to file reports.
2. Given I turn sharing on, then the screen says what is sent, that Claude is told to leave my
   secrets out, who can read it, and that I can turn it off at any time.
3. Given I turn it off, then nothing more is sent, and reports not yet delivered are dropped.

### US2 (P1): Claude reports what didn't work, without my secrets
1. Given sharing is on and a tool fails, then the answer reminds Claude to file a report.
2. Given Claude files a report, then it describes what failed without my passwords, codes, or
   full numbers: my own Claude decides what goes in, as it decides everything else it does.
3. Given my Mac is offline, then filing still works.

### US3 (P1): The developer's agent works through the reports
1. Given reports have arrived, when the developer's agent starts a session, then it sees how
   many are open, reads them, and dispositions each (fixed, duplicate, expected, can't fix),
   without any user's Mac or relay.
2. Given the intake were broken into, then the reports in it can't be read.

### US4 (P2): I run my own relay
1. Given I host a relay, then my users' shared reports go to Latchkey's developer by default
   (they chose to send them); I can point them at another developer's intake, or add a block so
   my relay forwards none.

## Requirements

### Opting in
- **FR-1400** The Mac app shall offer one setting, "Share problem reports with Latchkey's
  developer", Off for a new install.
- **FR-1401** While sharing is Off, Claude shall not see the `feedback` tool, nor any
  instruction or answer line about it (Constitution III).
- **FR-1402** When the Owner turns sharing on, the app shall say, before it takes effect, what a
  report holds, that Claude writes it and is told to leave secrets out, that only the developer
  can read it, and that it can be turned off at any time.
- **FR-1403** The setting shall belong to the account on its relay (the relay answers
  `feedback`); the Mac app sets it. Turning it off shall drop the account's reports not yet
  delivered.

### Asking Claude to report
- **FR-1405** While sharing is on, the relay's instructions to Claude shall ask it to file a report
  whenever anything done with Latchkey didn't fully work: an error, no response, a wrong or
  unclear answer, a workaround, or giving up.
- **FR-1406** While sharing is on, every tool answer that is an error shall end with one short
  line naming `feedback`.

### Filing
- **FR-1410** The relay shall answer `feedback` itself (summary, details, optionally the machine),
  whether or not any machine is online.
- **FR-1411** The `feedback` tool's description shall tell Claude that the report goes to
  Latchkey's developer and must not contain passwords, verification codes, full account or card
  numbers, message or email texts, or anything else private that the problem doesn't need. The
  relay doesn't inspect or change what Claude wrote: the user's own Claude is trusted with what
  it submits, as with everything else it does (Toni, 2026-11-23; Constitution X). Withdrawn idea:
  masking on the relay (pattern matching misses and mangles).
- **FR-1412** A shared report shall hold: the summary and details as Claude wrote them, the Claude app, the
  relay's and the machine's Latchkey versions, the machine's system version and screen state
  (locked or not), and a reporter tag that groups one account's reports without identifying it
  (it differs per relay and can't be reversed). It shall hold no account, email address,
  machine name, or relay address.
- **FR-1413** The relay shall encrypt each report to the developer's public key from its
  settings before storing or sending it; it never stores a report it could read.
- **FR-1414** The relay shall send each encrypted report to the intake address from its
  settings, retrying until the intake accepts it, then delete it. A report not accepted within
  7 days shall be deleted, and the relay's log shall say so.
- **FR-1415** Every relay, self-hosted ones included, shall forward its users' shared reports to
  Latchkey's developer by default: the user decides to send, so the opt-in is the user's (Toni,
  2026-11-23: "self-hosted relays will relay feedback since it's the end users deciding to send
  it, that's where the opt-in is"). A relay operator may set another intake address and developer
  key (a fork's developer).
- **FR-1415a** A relay operator may also block forwarding on their relay, as an additional block
  on top of the user's choice (Toni: "don't call it an opt out. just say it's an additional
  block"). While blocked, the setting of FR-1400 shall say this relay doesn't forward problem
  reports, and FR-1401 applies.
- **FR-1416** The answer to `feedback` shall say the report was queued for the developer, and
  never repeat its contents.

### The intake (the developer's)
- **FR-1420** The intake shall accept encrypted reports from anyone, at most 64 KB each, each
  with a small proof of work, and refuse anything else.
- **FR-1421** The intake shall limit how many reports one sending address may deliver per hour.
- **FR-1422** The intake shall never hold the developer's private key; it stores each encrypted
  report with the time it arrived.
- **FR-1423** With the developer's token, the intake shall list open reports, give one, and
  delete one once the developer's agent has dispositioned it (fixed, duplicate, expected, can't
  fix).
- **FR-1424** A report shall stay in the intake until it is dispositioned, then be deleted with
  nothing kept: the repository's history (the fixing change and its regression case) is the
  record (Toni, 2026-11-23: "they stay there until the dev agent dispositions them"; "Just delete
  it. Git is the history").
- **FR-1425** The intake shall be a program in this repository that a fork's developer can run
  for themselves.
- **FR-1426** Latchkey's own intake shall answer at the easy-to-remember name (latchkey on Toni's
  domain), which relays use by default; the hosted relay moves to a name that is hard to guess
  (Toni, 2026-11-23: "I prefer latchkey being for feedback, and moving our own relay to a more
  hard to guess DNS name"). The intake runs on pilvi, Toni's GCP VM (Toni). The relay's new name
  is never written in this repository (CLAUDE.md).

### The developer's agent
- **FR-1430** The developer's agent shall open reports with the developer's private key inside its
  own session; the key is never in the repository, CI, the intake, or any relay.
- **FR-1431** Report contents shall never be written to the repository, its pull requests, or CI
  logs; a regression case describes the problem in the agent's own words (CLAUDE.md, "Every
  issue becomes a regression case").

## Success criteria

- **SC-1401** With sharing Off, no `feedback` tool and no line about it appears (test suite).
- **SC-1402** A report filed with sharing on reaches the intake encrypted; the relay's database
  and the intake's hold no readable report at any time (test suite).
- **SC-1403** The `feedback` tool's description names what must stay out of a report (test).
- **SC-1404** The developer's agent lists, opens, and dispositions reports with no user's machine
  or relay involved.

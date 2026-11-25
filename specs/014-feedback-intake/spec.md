# Spec 014: Problem reports to Latchkey's developer — WHAT and WHY

Status: Built (Toni, 2026-11-23: "finish all the work without stopping"); amended 2026-11-25 (FR-1440 to
FR-1456, everything for the chat); tasks `tasks.md`.
Replaces spec 001 FR-691 to FR-693 (the relay keeping reports, delivering them to the Mac, the
Mac's Feedback folder), now withdrawn.
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
- **FR-1405** While sharing is on, the `feedback` tool's description shall ask Claude to file a
  report whenever anything done with Latchkey didn't fully work: an error, no response, a wrong or
  unclear answer, a workaround, or giving up. (The relay's general instructions to Claude are
  fixed for a whole session, so they no longer mention reports at all; FR-1401.)
- **FR-1406** While sharing is on, every tool answer that is an error shall end with one short
  line naming `feedback`.

### Filing
- **FR-1410** The relay shall answer `feedback` itself (summary, details, and the machines the
  problem involved), whether or not any machine is online.
- **FR-1410a** The `feedback` tool's description shall ask Claude to name every machine the
  problem involved, whenever one was (Toni, 2026-11-24: "make claude also name the machines
  involved in the feedback specifically").
- **FR-1411** The `feedback` tool's description shall tell Claude that the report goes to
  Latchkey's developer and must not contain passwords, verification codes, full account or card
  numbers, message or email texts, or anything else private that the problem doesn't need. The
  relay doesn't inspect or change what Claude wrote: the user's own Claude is trusted with what
  it submits, as with everything else it does (Toni, 2026-11-23; Constitution X). Withdrawn idea:
  masking on the relay (pattern matching misses and mangles).
- **FR-1412** A shared report shall hold: the summary and details as Claude wrote them, the Claude app, the
  relay's Latchkey version, and for each machine Claude named as involved, or, when it named
  none, for every machine online at the time (Toni, 2026-11-24), the machine's kind, Latchkey
  version, system version and screen state (locked or not), and a reporter tag that groups one account's reports without identifying it
  (it differs per relay and can't be reversed). It shall hold no account, email address,
  machine name, or relay address.
- **FR-1412a** A shared report shall hold the id the `feedback` answer gave Claude, so the user's
  chat and the developer's list name the same report (Toni, 2026-11-24).
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
- **FR-1420** *Amended 2026-11-25 (FR-1455):* the intake shall accept encrypted reports from anyone, at most 5 MB each (was 64 KB), each
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
- **FR-1426** Latchkey's own intake shall answer at `latchkey-feedback.melisma.net`, which relays
  use by default; it runs on the developer's own server, run outside this repository, with an
  ordinary certificate (the name is
  public by design: relays must know it, and it only takes in encrypted reports; it is not derived
  from the relay's name, which is never written here, CLAUDE.md). The hosted relay
  keeps its name (Toni, 2026-11-23: after the hosted server's agent's findings, moving it would have meant
  re-registered passkeys, a re-added connector, re-paired machines, a mail-name split and a stored
  DNS token for a small gain against mass scanning; "let's get a new hostname for the feedback.
  something specific to latchkey"). The DNS record exists since 2026-11-23.

### The developer's agent
- **FR-1430** The developer's agent shall open reports with the developer's private key inside its
  own session; the key is never in the repository, CI, the intake, or any relay.
- **FR-1431** Report contents shall never be written to the repository, its pull requests, or CI
  logs; a regression case describes the problem in the agent's own words (CLAUDE.md, "Every
  issue becomes a regression case").

### Everything for that chat (Toni, 2026-11-25)
Why: reports held only Claude's summary and the machines' versions (FR-1412), at most 64 KB. On
2026-11-25 two reports said Target's checkout "did nothing" in Latchkey's own browser while the
Mac was locked, and nobody could tell why: not the page, its requests, its errors, nor whether it
was drawing. Toni: "improve the feedback so in the future it automatically logs everything".
Choices (AskUserQuestion, 2026-11-25): "Everything for that chat"; "Same for everyone, said
plainly"; "Always record, memory only"; "5 MB, screenshots included"; "Hidden world".

- **FR-1440** A shared report shall hold, besides FR-1412, every tool call of the chat that filed
  it, each with its full arguments and the whole answer as Claude got it (images included), its
  time, duration, whether it failed, its call id, and which of the report's machines answered it
  (report format 3).
- **FR-1441** The chat shall be the connector session the `feedback` call came in on, together
  with each earlier session of the account in the last 24 hours that used one of the same
  Latchkey pages (a page's name is made for one chat; a chat idle for 30 minutes continues on a
  new session). A client without sessions shall get its calls from the same Claude app in the
  last 2 hours.
- **FR-1442** A shared report shall hold the relay's own log lines about the account from the
  first of those calls until the report, kept in memory only (the last 500 lines per account, for
  at most 24 hours), never written to disk for this.
- **FR-1443** For each machine the report involves (FR-1412) that is online and understands it,
  the relay shall ask the machine for its part, and wait for it at most 10 seconds (Constitution
  II). A machine that doesn't answer in time, can't be asked, or is offline shall be listed as
  such, and the report shall be filed without its part.
- **FR-1444** A machine's part shall hold: Latchkey's log on that machine for the time span
  (only the lines Latchkey's log tool would show, FR-662), its own trace of the chat's calls (the
  answer as it sent it, also when the relay had stopped waiting), and, on a Mac, a record of each
  page of the chat's (FR-1446, FR-1447).
- **FR-1445** The relay shall never offer the request for a machine's part as a tool to Claude,
  and refuse a machine that offers a tool of its name; a machine shall answer it only when the
  relay asks, and record that it did in its log, not as one of Claude's calls.
- **FR-1446** Latchkey's own browser shall keep, for each open page, a running record in memory
  only, never written to disk, dropped when the page closes, sent only inside a report: the last
  300 events of page loads (address, method where known, status), requests (address, kind,
  status where WebKit gives it, timing, size), uncaught errors, blocked content (security
  policy), and changes of the page's visibility. (Failed promises are not told to a world other
  than the page's own, so the record can't hold them; seen on GitHub's macOS runner, 2026-11-25.) It shall record from a script
  world the page can't see or notice, never by changing the page's own functions (Toni:
  "Hidden world"), so recording never changes how a site behaves.
- **FR-1447** At the report, each page of the chat's shall be described as it is: its address
  and title, its page source (the DOM, with every field's value and every hidden field's value
  blanked), its record (FR-1446), the names of its site's cookies (never a value), whether it is
  drawing (visibility state, focus, animation frames in half a second), its window and screen,
  and whether the Mac is locked and its display asleep; and a screenshot of a page in Latchkey's
  own browser. A page in the owner's Safari tabs shall be described only by reading it (address,
  title, page source, visibility, its requests from the page's own timing list), never by
  showing, moving, or changing anything the owner sees (Constitution IV), and without a
  screenshot.
- **FR-1448** Passwords and codes shall never be in a report: a code or password Claude passed
  to a tool in that chat shall be blanked wherever it appears in the report; the trace's own
  blanking (spec 013 FR-1372) holds; cookie values and field values are never collected. What
  Claude types into a password or code field of a page in Latchkey's own browser is known to the
  Mac and blanked; in Claude's Safari tabs a typed code is recognized only by its shape (4 to 8
  digits), since a check there would share the action's script and its bookkeeping (security
  review 2026-11-25); saved passwords and codes typed by logins_fill never reach the relay.
- **FR-1449** Each name of the account's machines, the account's email address, and the relay's
  own address shall be replaced in the report by a label ("machine 1"; "the account's email";
  "the relay"), so FR-1412's rule holds for the chat's calls too.
- **FR-1450** A report shall be at most 5 MB sealed. When it would be larger, the oldest calls'
  answers shall be left out first (each still listed with its tool, time, and that it was left
  out), then the oldest log lines, then page sources cut; the newest screenshot of a page the
  chat used stays as long as anything can.
- **FR-1451** When an intake refuses a report as too large (an intake from before FR-1420 was
  amended), the relay shall send instead the same report without FR-1440 to FR-1447's parts,
  saying they were left out.
- **FR-1452** The developer's command shall show a report's summary in its list, and with
  `show <id>` write the whole report to a new folder under the system's temporary folder, never
  inside a repository:
  the report, each call, each image as a picture file, each page's source and record, and the
  logs, as files the developer's agent can read.
- **FR-1453** The `feedback` tool's description shall say that the report also carries the
  chat's tool calls and answers, Latchkey's logs, and the pages the chat used, so Claude needn't
  copy them into details; details remain what Claude saw, expected, and tried.
- **FR-1454** Every account shall get the same reports (Toni: "Same for everyone, said
  plainly"), and the explanation of FR-1402 shall say in plain words that reports include the
  chat's tool calls with their answers, Latchkey's logs, and the pages the chat used, with
  passwords, codes, and cookie values left out.

Amended 2026-11-25: FR-1411 (the report's calls hold what the tools answered, which may include
message or email text; FR-1448 and FR-1449 still hold), FR-1412 (FR-1440 to FR-1449 add to it),
FR-1420 (5 MB, FR-1455), FR-1421 (FR-1456).

- **FR-1455** The intake shall accept reports of at most 5 MB sealed.
- **FR-1456** The intake shall also limit how many bytes one sending address may deliver per hour
  (50 MB) and how many bytes all waiting reports may hold together (5 GB), answering "busy" over
  either.

## Success criteria

- **SC-1401** With sharing Off, no `feedback` tool and no line about it appears (test suite).
- **SC-1402** A report filed with sharing on reaches the intake encrypted; the relay's database
  and the intake's hold no readable report at any time (test suite).
- **SC-1403** The `feedback` tool's description names what must stay out of a report (test).
- **SC-1405** A report filed through a real MCP client after browser and shell calls holds each
  call's arguments and answer, the relay's log, and each machine's part; a code passed to a
  tool is nowhere in it; a machine that doesn't answer in 10 s is listed as such (test suite).
- **SC-1406** A page in Latchkey's own browser leaves no record on disk, and its record is gone
  once it closes (test suite).
- **SC-1404** The developer's agent lists, opens, and dispositions reports with no user's machine
  or relay involved.

# Spec 010: Several machines and Linux servers — WHAT and WHY

Status: Built (2026-11-01; Toni asked on 2026-10-31 for the plan and the build in one go, without
a review stop). Plan, contracts, and tasks in this folder.
Scope: one Owner pairs several machines with one account (Macs, and Linux servers without a
screen), and Claude reaches all of them through the one connector. On a Linux server Claude gets
Shell and Files, the same tools as on the Mac.
Out of scope for now (Toni, 2026-10-31): status tools for a machine (the Mac has none either;
spec 001 FR-063 withdrawn), and server tools for services, containers, packages, processes, and
the network. Linux desktops (screen, browser, apps). Windows.

## Problem

Latchkey reaches one Mac. Many Owners also have a home server, a Raspberry Pi, or a rented
server, which sit behind a router or firewall just like the Mac. Today Claude can't reach them,
and pairing a second Mac replaces the first (spec 001 FR-053).

## Who

- **The Owner**: as in spec 001. Has one or more Macs and may have Linux servers. On a server
  they work in a terminal over SSH.

## User stories

### US1 (P1): All my machines behind one connector
1. Given my Mac and my home server are paired, when I ask Claude "how full is the disk on
   homeserver?", then Claude runs a command there and answers.
2. Given only one of my machines is online, when I ask for something without naming a machine,
   then Claude uses that one.
3. Given two machines could do it, when I don't say which, then Claude asks me or picks by
   name, never guesses silently.
4. Given homeserver is off, when I ask about it, then I hear at once that it's offline and since
   when, and my Mac keeps working.
5. Given a job across machines, when I ask "copy the backup log from homeserver to my Mac's
   Desktop", then Claude does it in one conversation.

### US2 (P1): Pair a server without a screen
1. Given I'm logged in to my server over SSH, when I run Latchkey's setup, then it shows a link
   and a short code, I approve it in a browser on my phone or Mac, and the server is paired.
2. Given the server restarts, then Latchkey comes back on its own, with nobody logged in.

### US3 (P1): Shell and Files on a server
1. Given Shell is On on the server, when I ask Claude to check why a backup failed, then it can
   read logs and run commands, with sudo where I allowed it without a password.
2. Given a photo or a PDF on the server, when I ask about it, then Claude can look at it.
3. Given I turn Shell off on the server, then Claude no longer sees Shell for that server.

## Requirements

### Several machines on one account

- **FR-1001** The Owner shall be able to pair several machines with one account, Macs and Linux
  servers in any mix. Pairing another machine shall add it, never replace one (withdraws spec
  001 FR-053, Toni, 2026-10-31).
- **FR-1002** Each machine shall have a name, by default its own (a Mac's computer name, a
  server's hostname), which the Owner can change on that machine (Toni, 2026-10-31). Two
  machines on one account shall never share a name.
- **FR-1003** One connector address shall reach every machine on the account (Toni,
  2026-10-31).
- **FR-1004** A tool shall appear to Claude while at least one paired machine offers it. A tool
  that works on more than one kind of machine (Shell, Files) shall appear once, not once per
  machine, and Claude shall say which machine a call is for.
- **FR-1005** When Claude calls a tool without naming a machine and exactly one online machine
  offers it, that machine shall run it. Otherwise the relay shall answer at once with the
  machines that offer the tool, each with whether it is online (Toni, 2026-10-31).
- **FR-1006** Claude shall be able to list the Owner's machines: name, kind (Mac or Linux),
  online or last seen, and the tools each offers.
- **FR-1007** When Claude names a machine that has the tool turned off, or that doesn't offer it,
  the answer shall be as if the tool didn't exist on that machine; the machine shall not be named
  among those offering it (Constitution III, per machine).
- **FR-1008** When a named machine is offline, the answer shall come at once, name the machine,
  and say since when and why if known (as spec 001's offline answers). The other machines shall
  be unaffected.
- **FR-1009** The state line added to every answer (spec 001 FR-065) shall name the machine that
  answered.
- **FR-1010** Every audit record and activity entry shall name the machine (spec 001 FR-630 to
  FR-637).
- **FR-1011** The Owner shall be able to see their paired machines and remove one, on the machine
  itself and on the relay's account page, for a lost, stolen, or wiped machine (Toni,
  2026-10-31); removing only takes access away.
- **FR-1012** Pairing a Mac while other machines are paired shall say it adds this Mac (spec 001
  FR-054's warning that it replaces the current pairing changes accordingly).

### Linux server: running and pairing

- **FR-1020** Latchkey shall run on 64-bit Linux with systemd, Intel and Arm, with no screen or
  desktop; it shall be tested on Ubuntu and Debian (Toni, 2026-10-31).
- **FR-1021** Latchkey shall run as the Owner's own account on the server, start when the server
  starts, and keep running with nobody logged in (Toni, 2026-10-31).
- **FR-1022** When the Owner runs setup on the server, it shall show a link and a short code; the
  Owner approves it in a browser on any device, signed in to the relay, on a page that names the
  server; the code shall expire after a short time and work once (Toni, 2026-10-31). The code
  shall be typed on that page, never carried in a link, and the page shall say when the machine
  asked and that the machine chose its name, so a code someone else sent can't be approved with
  one click (security review, 2026-10-31).
- **FR-1023** The server shall only connect out to the relay, never accept connections
  (Constitution I).
- **FR-1024** The Owner shall turn Shell and Files on and off on the server itself, with a command
  and its settings file; the relay shall never be able to turn anything on (Toni, 2026-10-31).
  Shell has Off and On; Files has Off, Read only, and Read & write. A newly paired server starts
  with Shell On and Files Read & write, as the Mac (spec 003 FR-209, spec 004 FR-308), with no
  question at setup (Toni, 2026-10-31).
- **FR-1025** The Owner shall be able to pause all of Claude's access on the server with a command,
  as the Mac's Pause (spec 001 FR-602 to FR-604).
- **FR-1026** Latchkey shall be installed on a server with one command that downloads a signed
  release. It shall check for a new release daily, check its signature, update itself, and go
  back to the previous version when the new one doesn't connect to the relay (Toni, 2026-10-31).
- **FR-1027** The Owner shall be able to uninstall Latchkey from a server with one command that
  removes its service, program, settings, and data, and unpairs the server (Constitution IV).
- **FR-1028** After installing, the `latchkey` command shall be on the Owner's path in a new login
  shell (found missing by the end-to-end check, 2026-11-01).
- **FR-1029** A release's signature shall cover its version and processor type as well as its
  contents, so an older release can't be offered as a newer one (security review, 2026-10-31).

### Linux server: Shell

- **FR-1030** While Shell is On, Claude shall run commands on the server as in spec 004 FR-301 to
  FR-305 and FR-309 to FR-312: in the Owner's login shell, in a chosen folder, in a terminal, with
  jobs that keep running, input, stop, and a limit of 32 at once.
- **FR-1031** Commands may use sudo (Toni, 2026-10-31; spec 004 FR-306 stays for the Mac). When
  sudo would ask for a password, the command shall not wait: Claude gets at once an answer saying
  sudo needs a password on this server and that the Owner can allow it without one (Toni,
  2026-10-31).
- **FR-1032** Leftovers shall be handled as on the Mac (spec 004 FR-313 to FR-316, FR-321,
  FR-322, FR-324, FR-326, FR-327): each command has its own scratch folder, and when it finishes,
  what it left running is stopped and the scratch folder removed, unless Claude asked to keep
  them for a time. This includes what a command started with sudo. There is no write fence on a
  server (Toni, 2026-10-31: a fence blocks sudo); spec 004 FR-317 to FR-320, FR-325, FR-328 to
  FR-330 are for the Mac only.
- **FR-1033** A removed scratch folder shall be deleted, not kept in a trash (as FR-1042).
- **FR-1034** When Shell is turned off or access paused, no command shall start afterwards, even
  one whose call arrived just before (security review, 2026-10-31).

### Linux server: Files

- **FR-1040** While Files is Read only or Read & write, Claude shall search files by name and
  content, list a folder, see a file's details, and read a file: text, the text of PDFs and
  documents, and images as images (as spec 003 FR-201).
- **FR-1041** While Files is Read & write, Claude shall create and change text files, edit a
  passage, create folders, and move, rename, copy, and delete files and folders (as spec 003
  FR-202, FR-204).
- **FR-1042** Deleting on a server shall delete for good (Toni, 2026-10-31; spec 003 FR-203 stays
  for the Mac). The tool's description and answer shall say so.
- **FR-1043** Files shall reach every file the Owner's account can open; Files itself never uses
  sudo. Latchkey's own files can be read but never changed, moved, or deleted (as spec 003 FR-205,
  FR-210).
- **FR-1044** File contents shall be marked as content, not instructions, and results shall stay
  within Claude's result size (as spec 003 FR-206, FR-207).

### Linux server: activity

- **FR-1050** Every command and file change on a server shall be recorded in an activity log on
  the server, readable by the Owner with a command, and in the relay's audit trail; there are no
  notifications (Toni, 2026-10-31). The server's log shall be compared with the relay's as the
  Mac's is (spec 001 FR-630 to FR-637).
- **FR-1051** The activity log shall be readable only by the Owner's account.

### Linux server: Latchkey's log for Claude (Toni, 2026-11-03: "fix everything, properly")

Why: the Mac offers Claude its own recent log lines so Claude can find out why Latchkey isn't
working (spec 001 FR-662 to FR-665); a server Claude can't diagnose is the same problem.

- **FR-1052** A server shall offer Claude the same read-only tool as the Mac's (spec 001 FR-662),
  with the same name and arguments, whatever Shell's and Files' levels, while it is connected;
  while access is paused it shall refuse it like every call.
- **FR-1053** The tool shall return only the program's own events recorded as public: never
  Claude's calls, their arguments or results, commands, call IDs, file paths, the relay's address
  or network addresses, and never an event recorded before the server could tell which of its
  events were public. When an event's words for the Owner hold such a detail, the server shall
  record a public version without it, or none.
- **FR-1054** When Claude asks, the tool shall answer as the Mac's does (spec 001 FR-664): the
  newest lines, newest last, 200 unless Claude asks for another number up to 1000, optionally of
  one kind of event only; each line with the time in the server's time zone, the kind, whether it
  was an error, and the text; the version that answered; and the oldest lines left out, saying
  how many, when they wouldn't fit in one answer.
- **FR-1055** When the activity log can't be read, the tool shall return this run's lines from
  memory instead and say so (as spec 001 FR-665).
- **FR-1056** The server shall record, as such events, its start and stop, each connection and
  why it ended, why it isn't connecting, an answer it couldn't send, setting and pause changes,
  updates and failed update checks, and the audit check, each in words without the details of
  FR-1053 (so a server that won't connect says why); the same failure repeated while
  reconnecting shall be recorded once.

## Success criteria

- **SC-1001** From the phone, with a Mac and a server paired, "how full is homeserver's disk?" is
  answered from the server, and "what's in my Mac's Downloads?" from the Mac, in one
  conversation.
- **SC-1002** With the server off, a call for it answers "offline" within a second, and a call
  for the Mac still works (test suite).
- **SC-1003** A server paired over SSH with no browser on it; after a reboot it is online again
  with nobody logged in.
- **SC-1004** With Shell off on the server, Claude's machine list doesn't show Shell for it, and a
  call naming it is answered as if the tool didn't exist there (test suite).
- **SC-1005** A command that starts a background process with sudo leaves nothing running once
  it finishes (test suite).
- **SC-1006** Claude looks at a photo stored on the server.

## Edge cases

- Two machines with the same hostname: the second gets a distinct name at pairing.
- A machine renamed or removed while Claude still uses the old name: the answer says the name is
  unknown and lists the machines.
- Claude's apps keep their own copy of the tool list. Linux adds no tool Mac Owners don't already
  see, so pairing a server changes no tool names; the machine list comes from a tool call, never
  from the tool list.
- A Mac and a server offering Files at different levels: the change tools appear (the Mac offers
  them); a call naming the read-only server is answered as if they didn't exist there.
- sudo configured to ask for a password for some commands only: those commands get the FR-1031
  answer; others run.
- A server without systemd, or 32-bit: setup says it isn't supported and stops.
- The server's disk full or clock wrong: setup and the connection say so plainly.

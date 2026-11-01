# Spec 009: Easy relay setup — WHAT and WHY

Status: Draft for Toni's review (2026-10-31). No plan, tasks, or code before the review.
Scope: a person with a Mac and a Claude subscription, and no technical background, gets their
own relay running, connected, and kept up to date, with as little effort as possible; a
technical person keeps every choice open (their own server, domain, host, email server).
Out of scope for now: a signed and notarized Mac app that updates itself (Toni, 2026-10-31:
Apple's Developer Program later); listing in Anthropic's connector directory.

## Problem

Running a relay today takes a server, a domain, Docker, and an email server for sign-up links
(docs/self-hosting.md). Toni's own relay is deployed by a script that assumes a Google Cloud VM
with Caddy and Cloudflare DNS. None of that is reachable for someone who has never used a
terminal, and the hosted relay is Toni's alone.

## Who

- **The Owner**: has a Mac, a Claude Pro or Max subscription (both include Claude Code, also in
  Claude Desktop's Code tab), and usually a payment card. Has never used a terminal and doesn't
  know what a server, DNS, or a container is.
- **The technical operator**: wants the relay on their own VPS, home server, Railway, or another
  host, under their own domain, with their own email server, backups, or proxy.

## User stories

### US1 (P1): Claude sets up my relay
1. Given I have installed Latchkey and have no relay, when I choose to set one up with Claude,
   then the app gives me one request to paste into Claude Code, and Claude Code guides me from
   there in plain language.
2. Given Claude Code is following the guide, then it does every technical step itself and asks
   me only for what only I can do: create an account with the host, confirm a card or phone
   number where the host requires it, click Allow in a browser sign-in, and make a passkey.
3. Given the setup is finished, then my relay answers on a web address that won't change, with
   HTTPS, my Mac is connected to it, and Claude (web, Desktop, phone) can use my Mac.
4. Given something fails on the way (the host is out of capacity, a sign-in is refused), then
   Claude says what happened in plain words and what we'll do instead.

### US2 (P1): No email server for a relay that's just mine
1. Given my relay is only for me, then it needs no email server: I claim it with a setup code
   Claude gives me, and nobody else can sign up.
2. Given I lose my passkey, then I ask Claude Code, and it lets me make a new one for my same
   account, so my Mac stays connected and nothing is lost (Toni, 2026-10-31).

### US3 (P1): It stays up to date and costs what I was told
1. Given a new relay version is released, then my relay updates itself, and goes back to the
   version before if the new one doesn't start; I do nothing.
2. Given anything could cost money, then Claude tells me what and how much before doing it, and
   sets up the host's spending alert where it has one.

### US4 (P2): I run it my way
1. Given I'm technical, then I can run the same relay on any server or host that runs a container,
   under my own domain, with my own email server, behind my own proxy, with my own backups, and
   the documentation tells me how.

## Requirements

- **FR-901** When an Owner without a relay chooses to set one up, the system shall offer one
  guided path that ends with the relay running, the Mac connected, and Claude's connector added,
  in which the Owner only creates accounts, confirms a card or phone where the host requires it,
  clicks browser sign-ins, makes a passkey, and adds the connector in Claude.
- **FR-902** The path shall be described in one document that Claude Code reads and follows: for
  each step, what Claude says to the Owner, what it runs, how it checks that the step worked, and
  what it does when the step fails. The Owner shall never be asked to type a command.
- **FR-903** The setup window shall offer, next to entering a relay's address, a way to set one
  up with Claude: a request to copy into Claude Code that points it at the document.
- **FR-904** The default host shall be Google Cloud's free server (one e2-micro in us-west1,
  us-central1, or us-east1 with a 30 GB standard disk; Toni, 2026-10-31: "default to google, not
  oracle"). Claude Code shall install Google's command-line tool itself, into the Owner's home
  folder, with no administrator password. Other hosts (Oracle, Railway, any server) are the
  technical operator's choice (FR-913).
- **FR-905** The relay's address shall be a host name that doesn't change, because passkeys and
  Claude's connector are tied to it; on a server without a name of its own, a name derived from
  its fixed public address shall be used (sslip.io), with no sign-up. The document shall tell the
  Owner that moving to another address later means making new passkeys and adding the connector
  again.
- **FR-906** HTTPS shall be set up without the Owner: by the host, or by the relay's own
  certificate (it already gets one from Let's Encrypt).
- **FR-907** When a relay is run with a setup code and has no account yet, it shall let only the
  person who enters that code create an account; once that account exists, sign-up shall be
  closed (unless the operator allows more people). Claude Code shall create the code, put it in
  the relay's settings, and give it to the Owner, so nobody reads server logs.
- **FR-908** A relay with no email server configured shall run, with sign-up by setup code only;
  an email server stays an option for relays shared with others.
- **FR-914** When the Owner has lost every passkey, Claude Code, signed in to the host as the
  Owner, shall be able to give the relay a new one-time recovery code; whoever enters it with the
  account's email address on the relay's page shall make a new passkey for that same account,
  keeping its Mac pairing, approvals, and records. The code shall work once and expire within an
  hour, and the relay shall record its use (FR-631). Why: no email server means no recovery link
  (Toni, 2026-10-31: "Claude Code resets it"); only someone who controls the host can do this.
- **FR-909** A relay set up this way shall install new released versions by itself, check that
  the new one starts, and go back to the version before when it doesn't; before a version that
  changes the database starts, a copy of the database shall be kept.
- **FR-910** Before any step that can cost money, Claude shall tell the Owner what it costs; where
  the host offers a spending alert, Claude shall set one at a small amount and tell the Owner.
- **FR-911** Every release of the relay shall be published as an image for both Intel and Arm
  servers, with a version tag and a `latest` tag, on ghcr.io (decided 2026-10-20 and 2026-10-31).
- **FR-912** The relay's session cookie shall be one that only its own host name can set or read
  (a `__Host-` cookie) whenever it runs on HTTPS, because a shared parent name such as sslip.io
  lets other sites under it set cookies.
- **FR-913** Every choice the default path makes (host, address, HTTPS, email, updates, backups)
  shall be a setting a technical operator can change, documented in docs/self-hosting.md; the
  default path shall need no code the operator path lacks.

## Success criteria

- **SC-901** A person who has never used a terminal goes from "Latchkey installed" to "Claude on
  the phone reads my grocery note" in under 30 minutes, with at most 8 actions of their own
  (accounts, card, sign-ins, passkey, connector).
- **SC-902** A run of the document from a fresh Mac and a fresh host account ends with a working
  relay, checked by a fresh Claude session calling a tool on the Mac.
- **SC-903** A new relay release reaches a relay set up this way within a day without anyone
  acting, and a release that doesn't start is rolled back.

## Known gaps

- The Mac app is signed only for Toni's Macs until Apple's Developer Program (later): anyone else
  must open it once through System Settings → Privacy & Security → Open Anyway. The document
  says so; it is the one step before Claude Code can help.
- The repository is public since 2026-10-31 (Toni: "everything public now"), so the document
  is reachable; the relay images (FR-911) are published once built.

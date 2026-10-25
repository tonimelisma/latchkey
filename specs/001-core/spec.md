# Spec 001: Core — connect Claude to my Mac

Status: Draft for review
Scope: the connection, sign-in, pairing, keep-awake, status, and one hello-world tool (`battery_status`).
Out of scope: files, Notes, iMessage, shell, browser and computer control (each gets its own spec).

This document says WHAT and WHY. Technology choices live in `plan.md`.

## Problem

People want Claude, on any device, to act on their own Mac. Claude's web and phone apps run in the
cloud and cannot reach a laptop behind a home router. Laptops also fall asleep, run out of battery,
and go offline, and when they do, the person using Claude should find out immediately instead of
waiting on a stalled request.

## Users

- **Owner**: installs the Mac app, owns the account, uses Claude on web, desktop, and phone.
- **Self-hoster**: an Owner who runs their own relay instead of the hosted one.

One Owner has one Mac in this spec.

## User stories

Priorities: P1 must ship together as the first usable version. Each story is independently testable.

### US1 (P1): Ask Claude about my Mac from my phone
As an Owner, I add one URL to Claude once, and from then on Claude on web, desktop, and phone can
call tools on my Mac.

Acceptance scenarios:
1. Given the Mac app is paired and online, when I ask Claude on my phone "what's my laptop's
   battery?", then Claude calls `battery_status` and reports the live percentage and charging state.
2. Given I added the connector on claude.ai on the web, when I open Claude on my phone and desktop,
   then the connector is already there without adding it again.
3. Given my Mac is behind a home router with default settings, when I set everything up, then I
   never configure the router, open a port, or install anything besides the Mac app.

### US2 (P1): Find out immediately when my Mac is unreachable
As an Owner, when my Mac is off, asleep, frozen, or has no network, Claude tells me right away and
tells me why, instead of hanging.

Acceptance scenarios:
1. Given the Mac has been shut down, when Claude calls any Mac tool, then within the response
   deadline Claude receives "Your Mac is offline since <time>" plus the last known battery and the
   reason if known.
2. Given the Mac went to sleep because of low battery, when Claude calls a tool, then the answer
   says it went to sleep for low battery and at what percentage.
3. Given the Mac is online but a tool call takes longer than its deadline, when the deadline
   passes, then Claude receives a timeout error and the Mac is told to cancel the call.
4. Given the Mac is offline, when Claude lists tools or calls `laptop_status`, then those still
   work, and the connector does not appear broken or signed out in Claude.

### US3 (P1): My Mac stays awake, safely
As an Owner, my Mac stays awake whether on battery or power and with the lid open or closed, but
sleeps rather than draining to zero or overheating.

Acceptance scenarios:
1. Given keep-awake is on, when I close the lid on battery, then the Mac stays awake and reachable.
2. Given keep-awake is on with the lid closed, when I plug in or unplug the charger, then the Mac
   stays awake.
3. Given the battery falls below the threshold while on battery, when that happens, then the Mac
   reports "going to sleep: low battery" to the relay, turns keep-awake off, and is allowed to sleep.
4. Given the Mac reaches a serious thermal state while keep-awake is on, when that happens, then it
   reports "going to sleep: too hot" and is allowed to sleep.
5. Given I quit or uninstall the app, when that happens, then normal sleep behavior is restored.

### US4 (P2): Sign up and sign in with a passkey
As an Owner, I create an account and sign in with a passkey only. If I lose my passkeys, I recover
with a link sent to my email.

Acceptance scenarios:
1. Given I am new, when I sign up, then I give an email and create a passkey; no password exists.
2. Given Claude asks me to connect the connector, when I approve, then I sign in with my passkey
   and Claude is connected.
3. Given I lost all passkeys, when I request recovery, then I get an emailed link that lets me
   register a new passkey, and the link works once and expires.

### US5 (P2): Pair my Mac with my account
As an Owner, I link the Mac app to my account without copying tokens around, and I can unlink it.

Acceptance scenarios:
1. Given a fresh install, when I click "Connect" in the menu bar app, then my browser opens, I sign
   in with my passkey, and the app shows "Connected".
2. Given a paired Mac, when I revoke it from the web account page or click "Disconnect" in the app,
   then the Mac can no longer receive tool calls.

### US6 (P2): Choose what Claude can do on my Mac
As an Owner, I choose in the app which capabilities exist. Anything I turn off is invisible to Claude.

Acceptance scenarios:
1. Given a capability is off, when Claude lists tools, then that capability's tools are absent.
2. Given I turn a capability on or off, when Claude next lists tools, then the list reflects it.

### US7 (P3): See what Claude did
As an Owner, I can see a log of tool calls: when, which tool, outcome, and duration on the account
page, and the full trace with arguments and results in the Mac app.

### US8 (P3): Run my own relay
As a Self-hoster, I run the relay as one container on my own server and point the Mac app at it.

## Requirements

Format: EARS ("When <trigger>, the <system> shall <response>"). IDs are stable; never renumber.

### Reachability
- **FR-001** The system shall let Claude on the web, Desktop, and the iOS and Android apps call
  tools on the Owner's Mac through one connector URL added once to the Owner's Claude account.
- **FR-002** The Mac app shall reach the relay using only outbound connections.
- **FR-003** The relay shall be reachable at a stable public HTTPS URL that does not change when
  the Mac goes offline or changes networks.
- **FR-004** When the network changes, the Mac wakes, or the relay restarts, the Mac app shall
  reconnect automatically, without user action.

### Offline and timeouts
- **FR-010** When Claude calls a Mac tool and the Mac is not connected, the relay shall return an
  error result that states the Mac is offline, since when, the last known battery and power state,
  and the reason it went offline if known.
- **FR-011** The relay shall bound every forwarded tool call with a deadline; when the deadline
  passes, the relay shall return a timeout error to Claude and send a cancel to the Mac.
- **FR-012** When the Mac stops responding without closing its connection, the relay shall mark it
  offline within a bounded detection window.
- **FR-013** While the Mac is offline, the relay shall still answer the MCP handshake and the tool
  list (last list the Mac reported); calling a Mac tool returns the offline answer (FR-010).
- **FR-014** While the Mac is offline, the relay shall keep the Owner's Claude connection signed
  in, including refreshing tokens.

### State the relay remembers
- **FR-020** The relay shall record, per Mac: connected or not, last seen time, last known battery
  percentage, power source, charging state, thermal state, keep-awake state, and the reason for the
  last disconnect if the Mac reported one.
- **FR-021** *Withdrawn 2026-10-22 (Toni): no status tool; the Mac's state is context in tool
  results (FR-065).*
- **FR-065** Every tool result that comes from the Mac shall end with a short line of the Mac's
  state (online, battery, power source, keep-awake, and a warning when the Mac may soon sleep),
  and every answer for a Mac that is away shall say since when and why, so Claude knows the
  laptop's condition as a byproduct of real work.
- **FR-022** The relay shall record an audit entry for every tool call: time, tool name, Claude
  surface if known, outcome (ok, error, timeout, offline), and duration. It shall not record tool
  arguments.
- **FR-023** The relay shall not store tool results.
- **FR-024** The relay shall delete audit entries older than 30 days.
- **FR-025** The relay shall not queue tool calls for later delivery.
- **FR-026** The Mac app shall keep a full local trace of every tool call it executes, including
  arguments, results, and errors, viewable in the app, stored only on the Mac.
  The app shall delete trace entries older than 90 days by default.
- **FR-026a** The Mac app shall store the trace encrypted, with a key only the app can read, so
  other programs on the Mac can't read it (Toni, 2026-10-24, security scan).

### Keep-awake and power
- **FR-030** While keep-awake is on, the Mac shall not sleep, on battery or power, with the lid
  open or closed.
- **FR-031** When the power source changes, the Mac app shall re-apply keep-awake and verify that
  it took effect.
- **FR-032** When the battery is at or below the low-battery threshold and on battery power, the Mac
  app shall report "low battery" to the relay, turn keep-awake off, and allow sleep. The threshold
  is fixed at 15% and is not user-adjustable.
- **FR-033** When the thermal state becomes serious or critical while keep-awake is on, the Mac
  app shall report "too hot" to the relay, turn keep-awake off, and allow sleep.
- **FR-034** When conditions return to normal (charger connected or battery above threshold;
  thermal state nominal or fair), the Mac app shall turn keep-awake back on automatically, unless
  the user turned it off.
- **FR-035** When the app quits, is uninstalled, or the helper is removed, normal macOS sleep
  behavior shall be restored.
- **FR-036** The Mac app shall report battery, power, thermal, and keep-awake state to the relay at
  least once per heartbeat interval and immediately on any change.
- **FR-037** The Mac app shall report its IANA time zone in its state, and the relay shall render
  times in offline messages in that time zone, falling back to UTC when unknown.

### Accounts and sign-in
- **FR-040** The relay shall authenticate Claude using OAuth as required by Claude's connector
  platform, so that the connector works on every Claude surface (see contracts/mcp-surface.md).
- **FR-041** The relay shall authenticate Owners with passkeys only.
- **FR-042** The relay shall offer account recovery by a single-use, expiring code sent by email
  that allows registering a new passkey; a code stops working after 5 wrong attempts.
- **FR-042a** When 20 wrong codes have been entered for one email address within a day, the
  relay shall refuse every emailed code for that address until the day is over; passkey sign-in
  keeps working (Toni, 2026-10-24, security scan).
- **FR-043** The relay shall verify the Owner's email address at sign-up with a code sent by email.
- **FR-043a** The relay shall offer one sign-in page for every journey: the Owner enters an email
  address and continues with a passkey for a known account, or an emailed code and a new passkey
  for a new account or a recovery, without leaving the page.
- **FR-044** An Owner shall be able to revoke Claude's access and revoke a paired Mac from a web
  account page.
- **FR-045** An Owner shall be able to delete their account and all data the relay holds about it.
- **FR-046** Where the relay operator has configured a list of allowed email addresses, the relay
  shall refuse sign-up for any other address; otherwise sign-up is open.
- **FR-047** When an Owner completes account recovery, the relay shall remove all of the Owner's
  previous passkeys.
- **FR-047a** When an Owner completes account recovery, the relay shall also remove every Claude
  client's access, so each must be approved again (Toni, 2026-10-24, security scan).
- **FR-048** The relay shall keep an Owner signed in to its web pages for 30 days, and shall ask
  for the passkey again before deleting the account.
- **FR-049** *Superseded 2026-10-25 by FR-049a (Toni): approvals are no longer remembered.* When
  an Owner has approved a Claude client once, the relay shall not ask again for the same client
  and scopes.
- **FR-049a** When a Claude client asks for access to the Owner's Mac, the relay shall show the
  Owner the consent page and give access only after the Owner allows it there, every time and
  for every client, including one the Owner allowed before and one on the Owner's own computer
  (Toni, 2026-10-25, security review).

### Pairing
- **FR-050** The Mac app shall pair with an account through a browser sign-in started from the app,
  without the Owner copying codes or tokens by hand.
- **FR-051** The Mac app shall store its credential in the macOS Keychain.
- **FR-052** When a Mac is revoked, the relay shall close its connection and reject its credential.
- **FR-053** When an Owner pairs a Mac while another Mac is paired, the relay shall name the
  current Mac, ask the Owner to confirm the replacement, and on confirmation revoke the current Mac.
- **FR-054** When a pairing link reaches the Mac app other than through the app's own sign-in
  window, the app shall connect only after the Owner confirms in a dialog that names the relay and
  the email address of the account the link belongs to, and says that it replaces the current
  pairing if there is one (Toni, 2026-10-24, security scan).

### Capabilities
- **FR-060** The Mac app shall let the Owner enable and disable each capability.
- **FR-061** The tool list Claude sees shall contain only tools of enabled capabilities, plus
  `laptop_status`.
- **FR-062** When the enabled set changes, the Mac app shall send the new tool list to the relay
  and the relay shall notify connected Claude sessions that the list changed, where the protocol
  supports it.
- **FR-064** *Withdrawn 2026-10-22 with FR-063.*
- **FR-063** *Withdrawn 2026-10-22 (Toni): the "System info" capability and `battery_status` are
  removed; the first real capability is Notes and Messages (spec 002).*

### Mac app behavior
- **FR-070** The app shall live in the menu bar and show: connected or not, battery, keep-awake
  state, and why keep-awake is off if it is.
- **FR-071** The app shall offer to start at login.
- **FR-076** On first launch, the app shall be set to start at login; the Owner can turn this off
  in the menu.
- **FR-077** When the Owner moves the app to the Trash while it runs, the app shall disconnect the
  Mac from the account, restore normal sleep, remove its login and background items and all its
  local data, and quit. When a newer copy replaces it instead (an update), the app shall hand over
  to the new copy without removing anything.
- **FR-079** While any of its windows is open, the app shall appear in the Dock and the app
  switcher (Cmd-Tab); with no window open it shall live only in the menu bar.
- **FR-078** On first launch, the app shall offer to move itself into the Applications folder,
  and shall show a setup window listing the remaining steps (approve keep-awake, connect to an
  account) until they are done.
- **FR-072** The app shall update itself through signed updates.
- **FR-073** All privileged operations shall go through Apple-supported mechanisms with standard
  system approval prompts.

### Platform
- **FR-075** The Mac app shall support the current and previous major macOS release, on Apple
  silicon Macs only.

### Self-hosting
- **FR-080** The relay shall run as one container with one data file, configured by environment
  variables, with no other required services except an SMTP server for email.
- **FR-081** The Mac app shall let the Owner choose a custom relay URL.
- **FR-082** The relay shall take a client's address from a proxy's forwarded-for header only when
  the proxy is on the same machine, or at an address the operator has listed as a trusted proxy
  (Toni, 2026-10-24, security scan).

## Success criteria

Measurable, technology-free. Each one has a test.

- **SC-01** From a fresh Mac and a fresh Claude account, setup takes under 5 minutes and under 10
  user actions, with no router or Terminal steps.
- **SC-02** With the Mac online, `battery_status` called from Claude on a phone returns in under
  3 seconds end to end, 95% of the time.
- **SC-03** With the Mac shut down, any tool call returns the offline answer in under 1 second at
  the relay, 99% of the time.
- **SC-04** With the Mac frozen or its network silently cut, the relay reports it offline within
  45 seconds.
- **SC-05** After network loss and recovery, the Mac is reachable again within 10 seconds of the
  network returning.
- **SC-06** (Checked in normal use, no dedicated test run; Toni, 2026-10-20.) With the lid closed on battery, the Mac stays reachable for 8 hours, including 3
  charger plug and unplug cycles, until the low-battery threshold.
- **SC-07** After the Mac has been offline 7 days, the Claude connector still works for
  `laptop_status` without signing in again.
- **SC-08** A disabled capability's tools never appear in Claude's tool list.
- **SC-09** Uninstalling the app restores default sleep behavior with no leftover background items.

## Edge cases

- The Mac reconnects while a call that timed out is still running: the late result is discarded.
- Two connections for the same Mac (for example after a network flap): the newest wins, the older
  is closed.
- The Mac is asleep but its connection has not closed yet: covered by FR-012.
- The relay restarts: Macs reconnect (FR-004); calls in flight fail with a clear error.
- Clock skew between Mac and relay: the relay's clock is authoritative for all timestamps.
- Recovery email is intercepted: links are single-use, short-lived, and recovery is announced to
  the account email and in the Mac app.
- The Owner revokes the Mac while a call is in flight: the call fails with "Mac disconnected".

## Open questions

- [NEEDS CLARIFICATION] Domain for the hosted relay. (Product name decided: Latchkey.)
- [LAUNCH BLOCKER, deferred] Terms of service, privacy policy, and abuse handling for the hosted
  relay. Not needed for development or private testing; required before public launch.

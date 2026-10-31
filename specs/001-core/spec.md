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
- **FR-200** The line of the Mac's state (FR-065) shall always start on a line of its own,
  whatever the result ends with (text with or without a line break at its end, empty text, an
  image, several parts, an error), without a blank line added where the text already ends with
  a line break, and without any change to the result itself.
- **FR-022** The relay shall record an audit entry for every tool call: time, tool name, Claude
  surface if known, outcome (ok, error, timeout, offline), and duration. It shall not record tool
  arguments.
- **FR-022a** The relay shall store a Claude surface's name only after removing control and
  formatting characters from it and cutting it to 64 characters, since the client chooses it
  (2026-10-25, security review).
- **FR-023** The relay shall not store tool results.
- **FR-024** *Amended 2026-10-27 (Toni):* the relay shall keep audit entries until the account
  is deleted; nothing is deleted by age (FR-630). Was: deleted after 30 days.
- **FR-025** The relay shall not queue tool calls for later delivery.
- **FR-026** The Mac app shall keep a full local trace of every tool call it executes, including
  arguments, results, and errors, viewable in the app, stored only on the Mac.
  The app shall keep every entry, images in results included, until the app is uninstalled;
  nothing is deleted by age (Toni, 2026-10-26; until then entries older than 90 days were
  deleted).
- **FR-026a** The Mac app shall store the trace encrypted, with a key only the app can read, so
  other programs on the Mac can't read it (Toni, 2026-10-24, security scan).
- **FR-201** The Mac app shall make a new key for the trace only when no key exists at all. If a
  key exists but cannot be read or is not a usable key, the app shall leave it as it is, write
  nothing in its place, and run without the trace until its next start: it shall keep working
  and answering Claude, say in the Activity window in one plain sentence that activity can't be
  shown or recorded and why, and try again each time it starts (Toni, 2026-10-25, after a read
  that always failed made the app replace the key on 2026-10-24).
- **FR-202** If the stored pairing exists but cannot be read, the Mac app shall not delete it or
  write over it: it shall start as not paired, record that the pairing is present but unreadable,
  and try again at its next start. Only the Owner disconnecting, uninstalling, or pairing again,
  or the relay revoking the Mac, removes or replaces a stored pairing.
- **FR-203** Trace entries that can no longer be read (saved with an earlier key) shall never be
  shown as tool calls or counted as failures: the menu's recent activity shall leave them out, and
  the Activity window shall say in one line how many older entries can't be read. They are kept
  like every other entry (FR-026; until 2026-10-26 they were deleted after 90 days).

### The activity log, kept for good (Toni, 2026-10-26)
- **FR-610** The Activity window shall show how much disk space the activity log uses.
- **FR-611** Disconnect This Mac, the relay revoking the Mac, and pairing again shall keep the
  activity log and its key; only uninstalling removes them (FR-077).
- **FR-612** Each entry recorded from this version on shall carry a keyed checksum over its
  content and the previous entry's checksum, so that removing, changing, or reordering entries
  breaks the chain. When the chain is broken, the Activity window shall warn, naming the first
  entry from which it doesn't hold, and mark the entries that don't check out. Entries recorded
  before this version stay readable and are shown, marked as from before the check. The upgrade
  to the new format shall change all existing entries or none.
- **FR-613** The Mac app shall keep a small record of the newest entry (its number and checksum)
  in the Keychain, updated with each entry, so that entries removed from the end of the log are
  also detected: the Activity window shall warn that newer entries are missing. A record that
  exists but can't be read shall not be written over and shall not cause a warning of missing
  entries; the window shall say in one line that this check can't be made right now, and the
  app tries again at its next start. A record that is missing while checked entries exist shall
  be said in one line too, and a new record started with the next entry.
- **FR-614** The Activity window shall load entries a page at a time, newest first, so years of
  entries open quickly, and shall let the Owner search the text of entries, choose one tool, and
  choose a date range. Searching shall work on the decrypted entries inside the app; nothing
  searchable is stored unencrypted (FR-026a stays as it is: Toni turned down an unencrypted log
  on 2026-10-26, since shell commands Claude runs could read it).
- **FR-615** "Export…" in the Activity window shall save the entries the window's search and
  filters currently select as readable JSON Lines (one entry per line: time in ISO 8601 with its
  UTC offset, tool, arguments, result, whether it failed, duration in milliseconds; since
  2026-10-27 also whether it is an action or an event, the call id, and the Claude app, FR-633,
  FR-637), to a place the Owner chooses in the standard save dialog. Entries that can't be read are left out.
- **FR-616** When the Owner opens the Activity window, the window shall appear at once and fill
  in as the log is read: no work over the whole log (the tamper check, counting unreadable
  entries, searching) shall run on the app's main thread or hold up the window, the menu, or
  recording, and the time the window and the menu wait shall not grow with the size of the log.
  Until the tamper check has finished, the window shall say it is checking and shall not mark
  any entry as checked (2026-10-29).
  Why (2026-10-29): the window once took about 10 seconds to appear on Toni's Mac (2026-10-27).
  The timing lines added then show, for the installed app on 2026-10-28 over its 18 MB log,
  0.2 s from choosing Show All Activity to the window and 0.23 s for the first page, so the
  small-rows change of 2026-10-27 holds; the 10 seconds weren't seen again. Reading every step
  that runs when the window opens found what does grow with the log, though: the tamper check
  and each start asked SQLite for "this key, after this number", which it answered by sorting
  every entry of the key, so the check's sorting grew with the square of the log (the whole
  check took 5 s at 100,000 entries; by estimate, the sorting alone a minute or more at a million) and
  each start read the whole log on the main thread; the menu counted unreadable entries
  over the whole log on the main thread after every call; and the window marked entries
  "checked" before the check had run. A new line says when the window is in front and whether
  the app was active, in case a window opened behind another app is what looked slow.

### Diagnostic log (Toni, 2026-10-27)
- **FR-620** The Mac app and its helper shall write to macOS's log, each time it changes: the
  keep-awake decision and whether the sleep setting took effect (with power source, lid, and
  heat), the helper's start, refusals, and errors, the relay connection's connects, closes
  (code and reason), and retries, network changes, sleep, wake, and shutdown, and each macOS
  permission request with its answer and every change in the permissions' states. These lines
  shall carry no message text, tool arguments or results, file names, or the relay's address in
  the clear. Why: keep-awake was silently off for two days (2026-10-25 to 2026-10-27) and nothing
  on the Mac said why.
- **FR-621** Every macOS permission the setup needs shall be known as allowed, missing, or not
  known yet. The setup window shall open only for steps known to be missing; a paired Mac shall
  wait up to 5 seconds at start for unknown states to settle, and the Permissions tab shall show
  an unknown state as "Checking…". Why: the setup window opened over a finished setup on
  2026-10-27 because Location read "not asked" for a moment at launch.
- **FR-623** At first run, the setup shall ask for every macOS permission every capability can
  use, whatever each capability's level, so that macOS never asks the Owner a question during use
  (Toni, 2026-10-31: "If I tell you to do all the allows on first run then do them"). As soon as a
  Mac is paired, the app shall ask each question macOS asks in its own dialog, one after another,
  each waiting for its answer (Notifications, Contacts, Calendars, Reminders, Location, control of
  Notes, Messages, Mail, and Safari, Local Network, and, once Screen Recording is allowed, one
  throwaway screenshot for macOS's direct screen access question), then open System Settings at
  the first switch only the Owner can turn on, and each time one is turned on, open the page of
  the next. The setup window shall have four steps (2026-10-31, after a review against Apple's
  guidelines found seventeen steps unwieldy): connect; answer macOS's questions (a checklist,
  with Ask Now to ask again and, for a question refused, a way to System Settings); turn on
  Latchkey in System Settings (a checklist and one button that opens the pages in turn); and
  Safari's setting. A permission refused or not yet given counts as missing and
  opens setup. The app shall never ask for a permission during use (no notification request when
  posting). Why: Toni got "Allow Latchkey to…" questions during use, when the Mac is usually
  unattended.
- **FR-624** When macOS's periodic screen question ("continue to allow", about once a month) is
  due for Latchkey and the Owner is at the Mac (the keyboard or pointer used within the last
  minute, the screen unlocked), the app shall take one throwaway screenshot, so that macOS asks
  then and not while Claude uses the Mac unattended; it shall try again at most once an hour
  while the question stays due. Why: macOS 27 still asks this (Toni's Mac, 2026-10-31: last
  asked Oct 23, next due Nov 22), and no app can turn it off.
- **FR-625** When a call fails because a macOS permission is missing (refused, never asked,
  or taken back after setup), Claude's answer shall name the permission and where the Mac's
  owner turns it on; and a call shall never run a script whose app macOS hasn't asked about
  yet, since that would raise macOS's question during use. Covers Automation of Notes,
  Messages, Mail, and Safari; Full Disk Access for Notes, Messages, Mail, Files, and Shell
  (macOS's "operation not permitted"); Contacts for names in Messages; a screenshot macOS
  refuses while Screen Recording is on; and Local Network for a Shell command that can't reach
  a device nearby. An app that isn't open is opened hidden to be looked at, as its script
  would open it anyway. Why: an audit on 2026-10-31 found these answered with
  a 25-second timeout, a raw error, or a silently empty result.
- **FR-626** While the app runs, it shall look every minute (Local Network every ten minutes),
  and after any call that fails, at every permission and setting setup asks for. When one that
  was on is found off, the app shall post one macOS notification naming it and what it is
  needed for (several found together share one notification); a click on it shall open setup.
  It shall be told once per loss, and again only after it was on again; the menu bar icon shall
  show its mark while anything is missing. It shall never ask a question or open an app to
  look (a closed app is looked at when it next runs or is used). Notifications itself and
  macOS's direct screen access question are not told: a notice can't arrive without the first,
  and macOS doesn't take back the second. Why: Toni asked (2026-10-31) to be told when a
  permission or setting goes missing; until now a lost permission showed only at the next
  start or in Claude's answers.
- **FR-622** After every install, the installer shall check the running app and fail when the
  setup window is open on a Mac whose setup is finished, keep-awake isn't what the app wants, or
  the keep-awake helper running isn't the one just installed.

### Audit trail without gaps (Toni, 2026-10-27)
Why: on 2026-10-27 an audit found the Mac's diagnostic lines discarded by macOS within hours,
the relay's output holding nothing but request noise, and the relay's audit deleted after 30
days; nothing checked that the two sides agree.
- **FR-630** The relay shall keep its audit of tool calls and its event record (FR-631) until
  the account is deleted. No entry shall be deleted by age.
- **FR-631** The relay shall record, with time, account, and Mac where they apply, and never
  content, tokens, codes, or keys: each Mac connection and its end (close code and reason, and
  the goodbye reason when the Mac said one); each change of the Mac's keep-awake state; each
  sign-in attempt and its outcome (passkey, emailed code, recovery link); each Claude app
  approved, refused, or removed; each pairing and unpairing; and each request it refused or
  failed (rejected token, rate limit, malformed request, internal error) with the reason.
- **FR-632** Every tool call shall carry an id that is unique for all time, made by the relay,
  stored in the relay's audit and in the Mac's activity log entry for that call.
- **FR-633** The Mac's activity log (FR-026, FR-610 to FR-615) shall also hold the app's own
  events: start and quit, the relay connection (connects, closes, retries, network changes),
  keep-awake decisions and whether they took effect, the helper's failures, sleep, wake, and
  shutdown, permission requests and changes, setup decisions, pause and resume, pairing changes,
  and errors. They are kept, encrypted, and chained like Claude's actions, shown in the Activity
  window (with a filter for events or actions), and exported with them. The lines in macOS's own
  log (FR-620) stay as well.
- **FR-634** The Mac app shall compare its log with the relay's audit of this Mac, by call id:
  every call the relay sent to the Mac must be in the Mac's log, and every call in the Mac's log
  must be in the relay's audit. It shall do this after each connection to the relay and when
  the Owner asks in the Activity window, record the result as an event naming every call
  missing on either side, and show a warning in the Activity window while any is missing.
  Calls from before call ids existed are left out and counted.
- **FR-635** The relay's own output shall carry the events of FR-631 as readable lines, and not
  a line per request.
- **FR-636** For every kind of event in FR-631 and FR-633 a test shall show that it is recorded,
  and a test shall show that no log, on the relay or the Mac, deletes entries by age. The
  installer shall fail when the Mac's comparison (FR-634) reports anything missing.
- **FR-637** The relay shall send with each call the name of the Claude app that made it (as it
  records it in its audit), and the Mac's activity log shall store and show it for that call
  (Toni, 2026-10-27: the audit found no way to tell on the Mac which app did what).

### Left Behind (Toni, 2026-10-27)
Why: on 2026-10-25 commands left processes and files on the Mac that nobody listed (spec 004).
- **FR-640** The Activity window shall show Left Behind entries on their own (a choice of the
  Show filter): what Shell commands left (spec 004 FR-323, FR-325), Claude's Safari window closed
  (spec 005 FR-411), and what Claude made through the other tools (FR-641).
- **FR-641** When Claude creates a file or folder, copies a file, or creates a note, event,
  reminder, or contact, the Mac shall record a Left Behind entry naming it.
- **FR-642** Left Behind entries shall be kept, encrypted, and chained like the other entries,
  and never written to macOS's own log (they name files; FR-620).
- **FR-643** The Owner shall be notified only of leftovers nobody meant to leave (spec 004
  FR-325), never of results Claude declared or things it made through the tools.
- Anything Latchkey removes on its own goes to the Trash (Toni, 2026-10-27).

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
- **FR-036a** When the Mac's state changes several times within a second, the Mac app shall
  report the first change at once and the latest state when the second is over, and shall not
  report again a state that hasn't changed, so a burst of changes can't flood the relay
  (security review, 2026-10-25).
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
- **FR-042b** When someone asks to recover an account, the relay shall answer with the same
  words and at the same speed whether or not the address has an account (2026-10-25, security
  review).
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
- **FR-047b** When an Owner creates a passkey with an emailed code (sign-up or recovery), the
  relay shall accept that code's confirmation for one passkey only, and shall end every other
  sign-up or recovery in progress for the account (2026-10-25, security review).
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
- **FR-052a** When a Mac is revoked while it is connecting, the relay shall close that connection
  as revoked as soon as it is established (2026-10-25, security review).
- **FR-053** When an Owner pairs a Mac while another Mac is paired, the relay shall name the
  current Mac, ask the Owner to confirm the replacement, and on confirmation revoke the current Mac.
- **FR-054** When a pairing link reaches the Mac app other than through the app's own sign-in
  window, the app shall connect only after the Owner confirms in a dialog that names the relay and
  the email address of the account the link belongs to, and says that it replaces the current
  pairing if there is one (Toni, 2026-10-24, security scan).
- **FR-054a** While the Mac app is handling one such pairing link (looking up its account, asking
  the Owner, or connecting), it shall ignore any further pairing link (security review,
  2026-10-25).
- **FR-054b** When a pairing link names a relay that isn't reached over an encrypted connection,
  the Mac app shall not use it; development builds alone accept a link to an unencrypted relay
  on the same Mac. The relay address the Owner types in is unaffected (security review,
  2026-10-25).

### Capabilities
- **FR-060** The Mac app shall let the Owner enable and disable each capability.
- **FR-061** The tool list Claude sees shall contain only tools of enabled capabilities, plus
  `laptop_status`.
- **FR-062** When the enabled set changes, the Mac app shall send the new tool list to the relay
  and the relay shall notify connected Claude sessions that the list changed, where the protocol
  supports it.
- **FR-066** When the Owner turns a capability off or lowers its level, the Mac app shall at once
  stop every running call that the new level no longer allows and answer each with an error
  saying that the Mac's owner turned that capability off, or down, in the app. Calls the new
  level still allows shall keep running, and raising a level shall stop nothing (Toni,
  2026-10-25).
- **FR-064** *Withdrawn 2026-10-22 with FR-063.*
- **FR-063** *Withdrawn 2026-10-22 (Toni): the "System info" capability and `battery_status` are
  removed; the first real capability is Notes and Messages (spec 002).*

### Mac app behavior
- **FR-070** The app shall live in the menu bar. Its menu shall start with whether Claude can
  reach the Mac and, when it can't, why. It shall show keep-awake's state only when keep-awake is
  off for a reason the Owner didn't choose, and then say why (as one clickable line when the
  Owner can fix it). It shall not show the battery: macOS shows it, and Claude sees it in every
  result (Toni, 2026-10-26).
- **FR-071** The app shall offer to start at login.
- **FR-076** On first launch, the app shall be set to start at login; the Owner can turn this off
  in the Settings window (FR-601).
- **FR-077** When the Owner moves the app to the Trash while it runs, the app shall disconnect the
  Mac from the account, restore normal sleep, remove its login and background items and all its
  local data, and quit. When a newer copy replaces it instead (an update), the app shall hand over
  to the new copy without removing anything.
- **FR-079** While any of its windows is open, the app shall appear in the Dock and the app
  switcher (Cmd-Tab); with no window open it shall live only in the menu bar.
- **FR-078** On first launch, the app shall offer to move itself into the Applications folder,
  and shall show a setup window listing the remaining steps (approve keep-awake, connect to an
  account) until they are done.
- **FR-205** When the app starts and every setup step is already done, it shall open no window
  and shall appear only in the menu bar (not in the Dock or the app switcher). It shall show the
  setup window at start only while a step is really unfinished.
- **FR-600** The menu bar icon shall show the Mac's state by its shape alone, never by color
  (Toni, 2026-10-26): a solid key while Claude can reach the Mac; a key with a line through it
  while it can't (offline, connecting, not paired, or refused by the relay); a small pause mark
  beside the key while paused (FR-602); a small "!" beside the key while a setup step is
  unfinished; and a small dot beside the key while a request from Claude runs (spec 002
  FR-132). Only one mark shows at a time, in that order of precedence. Its spoken description
  shall say the same in words.
- **FR-601** Settings the Owner changes rarely shall be in a Settings window (opened from the
  menu with "Settings…" and Command-comma), not in the menu (Toni, 2026-10-26): what Claude can
  do (each capability's level), the macOS permissions (FR-606), the Claude apps with access
  (FR-190), the connection (the
  relay's address, Disconnect This Mac), and starting at login. Changes there take effect at
  once. The menu keeps the status, Keep Mac Awake, Pause, recent activity, Settings, and Quit.
- **FR-602** The menu shall have a "Pause Claude's Access" item (Toni, 2026-10-26). While paused,
  every request from Claude shall be answered at once with an error saying the Mac's owner
  paused Latchkey on this Mac; capability levels, the pairing, and keep-awake stay as they are;
  the menu's first line says the Mac is paused; and the item reads "Resume Claude's Access".
- **FR-603** When the Owner pauses, the Mac app shall at once stop every running request and
  every running shell command, answering each request with the same error as FR-602.
- **FR-604** Pausing shall last until the Owner resumes, including across quitting, restarts,
  and updates.
- **FR-605** Disconnect This Mac shall ask for confirmation first, with the destructive button
  not the default, since it can only be undone by pairing again.
- **FR-606** The Settings window shall list every macOS permission Latchkey uses (keep-awake in
  the background, Full Disk Access, Notifications, control of Notes, Messages, Mail, and Safari,
  Contacts, Calendars, Reminders, Location, Local Network, Safari's JavaScript setting, Screen
  Recording, macOS's direct screen access question, Accessibility) at any time, not only while
  setup is unfinished (Toni, 2026-10-26). Each shows whether it is allowed or missing (or still
  being checked), with a button that does what the setup step does. Changes made in System
  Settings show within a second while the window is open. (Amended 2026-10-31: every permission
  is needed whatever the levels, FR-623.)
- **FR-072** The app shall update itself through signed updates.
- **FR-074** A development or test build of the app shall be a different app from the installed
  one in macOS's eyes: it shall not share the installed app's settings, stored pairing and keys,
  privacy permissions, or keep-awake helper, and shall not receive the installed app's links
  (Toni, 2026-10-25).
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

### Limits that keep the relay standing (2026-10-25, security review)
- **FR-090** When a Claude session has received no request for 30 minutes, the relay shall end
  it. The relay shall keep at most 64 sessions per Owner, ending the oldest to make room, and
  shall keep nothing in memory for Claude's sessions once the Owner's account is deleted or
  Claude's access is removed.
- **FR-091** When a connected Mac sends messages faster than 60 at once and 5 per second after
  that (answers the relay is waiting for not counted), or a tool list of more than 256 tools or
  512 KiB, the relay shall close the connection as a protocol violation.
- **FR-092** When a Mac connects, the relay shall verify its signature before it processes
  anything else the Mac sent.
- **FR-093** When a request from Claude is cancelled or its client goes away, the Mac's
  connection shall stay up.
- **FR-094** When a client takes longer than 30 seconds to send a request's body (2 minutes for
  a request to the connector URL, which may carry a file), the relay shall stop waiting for it.
  Answers that take long, and the Mac's connection, are not affected.
- **FR-095** The relay shall keep a Claude client's published description (its metadata
  document) for at least 5 minutes and at most a day before fetching it again; when a new fetch
  fails, it shall keep using the last good copy for up to 7 days and shall not fetch that address
  again for 5 minutes; it shall keep at most 1,000 descriptions of clients that hold no access,
  deleting those unused for a day; and it shall never tell a client or browser why a fetch
  failed.
- **FR-096** When one sign-in code from Claude is presented more than once, even at the same
  moment, the relay shall give access for it at most once and shall end the access it gave.
- **FR-097** When the relay sends the Owner's browser back to a Claude client, with a code or
  with an error, it shall say which relay the answer comes from, and shall announce that it
  does so (RFC 9207).
- **FR-098** The relay shall remove every kind of bracket, in any script, from a client's name
  before showing it, so a name can't imitate the checked host that is shown after it in
  parentheses.
- **FR-099** While 10,000 passkey sign-ins are in progress, the relay shall answer a further one
  with "Too many sign-ins are in progress right now. Try again in a minute." instead of holding
  more in memory.

### Only Claude's apps, and the relay's own keys (Toni, 2026-10-25)
- **FR-180** The relay shall accept a client that asks for access only when the address the
  client identifies itself with is on a host in the operator's list of allowed client hosts.
  The list holds exact host names (no wildcards, compared in lowercase ASCII form) and is
  "claude.ai" unless the operator sets it; the single value `*` means any host.
- **FR-181** While the list is not `*`, the relay shall accept a client's published description
  only when every address it may send the Owner's browser back to is on an allowed host or on
  the Owner's own computer (a loopback address, as Claude Code uses).
- **FR-182** While the list is not `*`, the relay shall not register clients on request: it
  shall answer a registration with an error that says so, and shall not announce a registration
  address. It shall keep announcing the two signals that make Claude identify itself by a
  published description.
- **FR-183** When the relay refuses a client under FR-180 to FR-182, it shall do so before making
  any request to that client's host, shall answer with an OAuth error that says in words "This
  relay only accepts Claude's apps." (or, with an operator's own list, names the allowed hosts),
  and shall not send the Owner's browser to the refused client.
- **FR-184** When the relay starts, and once a day after that, it shall delete every stored
  client the list no longer allows, with all its codes and tokens; until then it shall refuse
  any use of them.
- **FR-185** If the list of allowed client hosts is not valid (an entry that is not a host name,
  `*` mixed with other entries, or only separators), then the relay shall refuse to start and
  say why.
- **FR-186** The relay shall keep its own signing keys in its database only in encrypted and
  tamper-evident form, under a key kept in a separate file (the key file) that is not part of
  the database. The stored form shall carry a version, so the method can change later.
- **FR-187** When the relay starts and has no key file and no encrypted keys, it shall create
  the key file, readable by the relay's own user only, never replacing an existing file, and
  shall log that it did (never the key). If the key file can be read by other users, or is not
  the right size, then the relay shall refuse to start and say why.
- **FR-188** When the relay starts with signing keys stored unencrypted by an earlier version,
  it shall encrypt them all in one step: each new value is read back and compared before it
  replaces the old one, and if any step fails nothing is changed. Access given to Claude before
  the change shall keep working after it.
- **FR-189** If encrypted keys exist and the key file is missing, unreadable, or does not open
  every one of them, then the relay shall refuse to start, and say what happened and the two
  ways out: put the key file back, or delete the stored keys with an explicit operator command.
  That command shall sign everyone out and end Claude's access, and shall keep accounts,
  passkeys, and paired Macs. The relay shall never delete its keys by itself, and shall never
  put key material in a log or an error.

### Apps with access, shown on the Mac (Toni, 2026-10-25)
- **FR-190** While the Mac is connected to a relay that reports them, the Mac app's Settings
  window (FR-601; the menu until 2026-10-26) shall show
  the Claude apps that have access to the Owner's Mac: for each approval the Owner gave that
  still works, the app's name and the checked host as the consent page showed them, where the
  approval was sent back to, when it was given, and when it was last used. The relay shall
  report them only to an app that said it understands the report.
- **FR-191** When the Owner removes one app in the Mac app, that app shall lose its access at
  once (its sign-in codes and tokens stop working and its open sessions are closed) while every
  other approval keeps working; the Mac app shall log the removal and report a failure when the
  relay hasn't confirmed it within 5 seconds. The relay's account page shall offer the same
  removal of one app. A request naming an approval of another account, or one that doesn't
  exist, shall change nothing.
- **FR-192** When access is given or removed anywhere (a new approval, a removal on the Mac or
  the account page, a recovery, a client giving up its own access, a token found reused, an
  approval found expired), the relay shall send the Mac app the full current list. The relay
  shall record when an approval was last used at most once a minute per approval, and a newer
  last-used time alone shall send nothing.

### Terms and privacy policy (Toni, 2026-10-25)
- **FR-193** Where the person running a relay has set their name and a contact email address,
  the relay shall publish terms of service and a privacy policy, link both from every page it
  shows, say "By continuing, you agree to the Terms and the Privacy Policy" where an account is
  created, and announce both documents to Claude clients. Where they aren't set, the relay shall
  publish neither document and show no links. The relay shall refuse to start when only one of
  the two is set or the contact isn't an email address.
- **FR-194** The privacy policy shall name every kind of data the relay stores, how long it is
  kept, and what the relay never stores; each document shall show the date it took effect; and
  everything about the person running the relay shall come from their settings, never from the
  software.

### Dealing with abuse (Toni, 2026-10-25)
- **FR-195** The person running a relay shall be able, on the relay's own server, to list the
  accounts (without secrets), suspend an account with a reason, lift a suspension, delete an
  account (with the same effect as the Owner's Delete account), and block or unblock an email
  address and list the blocked ones. Each command shall say in one line what it did, shall
  report failure to the program that ran it, and shall be recorded with who ran it, what it did,
  and when.
- **FR-196** When an account is suspended, the relay shall end every browser sign-in of the
  account, refuse sign-in and recovery for it with a plain message (naming the contact address
  when one is set), remove every Claude app's access and refuse the connector, and close the
  Mac's connection and refuse new ones without making the Mac app forget its pairing. Nothing
  else shall be deleted. When the suspension is lifted, the Owner shall be able to sign in again
  and approve Claude again.
- **FR-204** When the relay refuses or closes the Mac's connection because its account is
  suspended, the Mac app shall say that the account is suspended on the relay and that the
  relay's operator is the one to contact (it shall not ask the Owner to sign in again), keep its
  pairing, and try to connect again every 5 minutes, and at once when the Mac wakes or its
  network changes, so that it reconnects by itself once the suspension is lifted. Any other
  failed authentication behaves as before (Toni, 2026-10-25).
- **FR-197** When an email address is blocked, the relay shall refuse sign-up and sign-in for
  it, and shall suspend its account if it has one.
- **FR-198** While the relay is running, a suspension, block, or deletion made by its operator
  shall take effect on every new request at once, and on connections that are already open (the
  Mac's, and Claude's open sessions) within 5 seconds.
- **FR-199** The relay shall delete the record of an operator's action after one year.

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
- The Owner turns a capability off or down while one of its calls is in flight: the call is
  stopped and answered with the reason (FR-066). A change it had already made stays made.

## Open questions

- [NEEDS CLARIFICATION] Domain for the hosted relay. (Product name decided: Latchkey.)
- [LAUNCH BLOCKER, built 2026-10-25, wording not yet reviewed] Terms of service, privacy policy
  (FR-193, FR-194), and abuse handling (FR-195 to FR-199) for the hosted relay. The two
  documents are plain-language drafts, not legal advice: the owner has them reviewed before
  opening sign-up to the public.

# Spec 005: Browser control — WHAT and WHY

Status: Approved to build without a review stop (Toni, 2026-10-22); Toni reviews at the end.
Scope: Claude uses the Owner's Safari on the Mac, with the Owner's logins: opens pages, reads
them, follows links, fills in and submits forms, in its own tab and, since 2026-11-03, in any of
the Owner's tabs and windows (Toni: "Claude needs to be able to access my tabs and windows just
like its own").
Out of scope: other browsers (Toni chose Safari, 2026-10-22); clicks that need a real mouse
(computer control, spec 006).

## Problem

Many sites have no API and no connector, and the Owner is signed in to them on the Mac. From a
phone, Claude can't check a reservation in the Owner's account or fill in a form there.

## User stories

### US1 (P1): Read sites I'm signed in to
1. Given Browser is Read only or more, when I ask "what's my next delivery on my grocery site?",
   then Claude opens the site in Safari on my Mac, signed in as me, and reads the answer.

### US2 (P1): Act on sites
1. Given Browser is Read & write, when I ask Claude to fill in and send a form, then it does.

### US3 (P1): Stay out of my way
1. Claude works in a Safari tab of its own (or, if I choose, a window of its own) and never
   touches my other windows and tabs. (2026-11-03, Toni: withdrawn in part: Claude opens its pages
   there, and reaches my other tabs and windows too, US4; it still never brings them forward.)
2. Given Claude's page is a tab in my window, when Claude works, then the tab I'm using stays in
   front and Claude works in its tab behind it (Toni, 2026-10-29).

### US4 (P1): Use my tabs (Toni, 2026-11-03)
1. Given Browser is Read only or more, when I ask "what do I have open in Safari?", then Claude
   lists every tab of every window, with its title and address, and which is in front.
2. Given that list, when I ask Claude to read one of my tabs, or (Read & write) to click, type,
   go back, or close it, then Claude does so just as in its own tab, in the background: the tab I
   have in front stays in front.

## Requirements

- **FR-401** While Browser is Read only or Read & write, Claude shall be able to open a web
  page, read its text, links, buttons, and fields, list and switch its tabs, and go back.
- **FR-402** While Browser is Read & write, Claude shall be able to click links and buttons,
  type into fields, choose options, submit forms, and run its own script in the page.
- **FR-403** Claude shall use the Owner's Safari with the Owner's logins and saved sessions
  (Toni, 2026-10-22), in a window of its own; it shall not read or change the Owner's other
  windows and tabs. (2026-10-29: "a window of its own" became a tab or a window of its own,
  FR-412; the Owner's other tabs, including those in the window that holds Claude's tab, stay
  untouched.) (2026-11-03, Toni: "it shall not read or change the Owner's other windows and
  tabs" is withdrawn: Claude reaches every tab and window, FR-424 to FR-431.)
- **FR-404** Page content shall be marked as written by the website, not instructions.
- **FR-405** Results shall stay within Claude's result size, with a way to read on.
- **FR-406** When Safari's "Allow JavaScript from Apple Events" or the Automation permission is
  missing, the setup window shall show the step, and tools shall explain what to turn on.
- **FR-407** Browser shall have the levels Off, Read only, Read & write, and start at Read &
  write (Toni, 2026-10-22).
- **FR-408** Each click, typing, and script Claude does shall appear in the menu's activity.
- **FR-409** Browser shall open only http and https addresses (and about:blank); other kinds,
  such as javascript:, file:, and data:, shall be refused (Toni, 2026-10-24, security scan).
- **FR-410** When Claude reads a page, Browser shall not give it what a password field holds,
  nor what a field holds that the page marks as a password, a one-time code, or a card number
  or security code; it shall say only that the field is filled in. Claude shall still be able
  to type into such a field while Browser is Read & write (security review, 2026-10-25).
- **FR-411** When Claude hasn't used its Safari window for 30 minutes, Browser shall close that
  window and record it as a Left Behind entry (spec 001 FR-640; Toni, 2026-10-27: the Mac can't
  tell when a conversation ends, and the relay ends a quiet Claude session after 30 minutes),
  also when Latchkey restarted or was updated in between (Toni, 2026-10-29). (2026-10-29: when
  Claude's page is a tab, FR-412, Browser closes that tab instead, the same way.) (2026-10-29,
  Toni: also when Safari restarted and brought Claude's own window back; Claude's tab, which can't
  be told from the Owner's then, is left alone and noted under FR-418.)
- **FR-412** Browser shall open Claude's pages either in a tab of the Owner's Safari window or
  in a Safari window of Claude's own, as the Owner chooses in Latchkey's Settings, and shall
  start with a tab (Toni, 2026-10-29).
- **FR-413** While Claude's page is a tab, Browser shall open it in the background, at the end
  of the Owner's front Safari window: the tab the Owner has in front stays in front, and Claude
  reads, clicks, types, and runs scripts in its own tab behind it (Toni, 2026-10-29).
- **FR-414** When Claude's page is to be a tab and Safari has no window open, Browser shall open
  a new window and use its tab (Toni, 2026-10-29).
- **FR-415** While Claude's page is a tab, a screenshot of it (spec 006 FR-509) shall bring
  Claude's tab to the front for the shot and then bring back the tab that was in front, also
  when the shot fails; a tab the Owner switched to meanwhile stays (Toni, 2026-10-29).
- **FR-416** While Claude's page is a tab, Claude's tabs shall be the one tab it opened: a page
  Claude opens, also one it asks for in a new tab, loads in that tab, and the list of tabs shows
  that tab alone (2026-10-29). (2026-11-03: "the list of tabs shows that tab alone" is withdrawn:
  the list shows every tab, FR-424; Claude's pages still load in its one tab, FR-426.)
- **FR-417** When the Owner changes where Claude's pages open, the next page Claude opens shall
  follow the new choice, and Browser shall close Claude's previous tab or window (2026-10-29).
- **FR-418** When Browser can't tell for sure which tab is Claude's (the Owner closed it, or
  tabs moved while its page changed), it shall leave every tab alone, record a Left Behind entry
  saying it lost track of Claude's tab, and open a new tab for Claude's next page (2026-10-29).
- **FR-419** While Browser is Read & write, Claude shall be able to close its own tab or window,
  never one of the Owner's (Toni, 2026-11-01: "open tabs and close"). (2026-11-03: "never one of
  the Owner's" is withdrawn: FR-428.)
- **FR-420** While the Mac is locked, the browser tools shall work in a browser of Latchkey's
  own, signed in with the Owner's Safari cookies as they are when it starts (Toni, 2026-11-02:
  Safari stops answering while locked).
- **FR-421** The copy of Safari's cookies shall be kept only in memory: never written to disk,
  logged, shown to Claude, or sent off the Mac.
- **FR-422** When the Mac is unlocked, Latchkey's own browser shall be closed with its cookies,
  and the browser tools shall use Safari again.
- **FR-423** When a picture of Claude's page needs Claude's tab brought to the front of the
  Owner's Safari window, Latchkey shall do so only while the Owner can't see that window
  (covered, or on another desktop); while they can, the picture shall be of the same address in
  Latchkey's own browser, saying so (Toni, 2026-11-02: "Switch only when hidden").

- **FR-424** While Browser is Read only or Read & write, Claude shall be able to list every tab of
  every Safari window: each tab's title and address, the window it is in, the tab in front of
  each window, the window in front, Claude's own tab, and the tab Claude is working in (Toni,
  2026-11-03: "Claude needs to be able to access my tabs and windows just like its own").
- **FR-425** When Claude picks a tab from that list, the browser tools shall work in that tab
  as they do in Claude's own: read it, go back, and take its picture, and, while Browser is
  Read & write, click, type, run a script in it, and close it. Claude shall keep working in that
  tab until it opens a page, picks another tab, or leaves it unused for 30 minutes (2026-11-03).
- **FR-426** When Claude opens a page, Browser shall load it in Claude's own tab or window, as
  before (FR-412 to FR-417), and Claude shall work in its own page again (Toni, 2026-11-03).
- **FR-427** While Claude works in one of the Owner's tabs, Browser shall leave it where it is:
  it shall not bring that tab or its window forward or change which tab is in front, except
  for a picture as FR-423 allows (2026-11-03).
- **FR-428** While Browser is Read & write, Claude shall be able to close the tab it is working
  in, its own or one of the Owner's (Toni, 2026-11-03).
- **FR-429** Before reading or acting on one of the Owner's tabs, Browser shall check that it is
  still the tab Claude picked: in the same window, with as many tabs in that window as before,
  showing the page it showed or one Claude's own click, typing, or back went to under the same
  rules as Claude's own tab (plan D6). Otherwise it shall do nothing to any tab and tell Claude to
  list the tabs again (2026-11-03).
- **FR-430** While the Mac is locked (FR-420), Claude's own page shall stay in Latchkey's own
  browser, and the Owner's tabs shall still be listed, picked, and used through Safari while
  Safari answers; when Safari doesn't answer, Claude shall be told that the Owner's tabs can't
  be reached until someone unlocks the Mac (2026-11-03: Safari stopped answering scripts while
  locked on 2026-11-01, and answered the list and page scripts while locked on 2026-11-03).
- **FR-431** An answer from one of the Owner's tabs shall say which tab it came from, and the
  tab list shall mark the titles and addresses as written by websites, not instructions
  (FR-404; 2026-11-03).
- **FR-432** A page's own dialogs (an alert, a confirm, a prompt) shall never make Claude wait,
  in Safari or in Latchkey's own browser, locked or not: in the tab Claude works in, an alert
  shall be dismissed, a confirm answered Cancel unless Claude's action says OK, and a prompt
  given Claude's text or none, and the next answer shall say what each said. When a page
  already waits on a dialog it showed before Latchkey's answers were in it, Claude shall be told
  so within about 2 seconds (Claude's own page can then be loaded over or closed; the Owner's
  tab is left as it is), instead of waiting for Safari's time limit (Toni, 2026-11-03: "25
  seconds to stall on Claude is too much"; "Answer them, Claude can say OK").

## Success criteria

- **SC-401** From the phone, Claude reads a page of a site the Owner is signed in to on the Mac.
- **SC-402** With Browser Read only, no tool that clicks or types appears (test suite).
- **SC-403** From the phone, Claude lists the Owner's Safari tabs and reads one of them, and the
  tab the Owner has in front stays in front (2026-11-03).

## Edge cases

- The Owner closes Claude's window or tab: the next request opens a new one (FR-418).
- The Owner closes or moves the tab Claude is working in, or opens or closes another tab in its
  window: Claude is told to list the tabs again (FR-429).
- One of the Owner's tabs shows a page Safari lets no script into (an empty new tab, Safari's
  own pages): it is listed, but reading or acting on it says so.
- The Owner moves or closes other tabs in the window that holds Claude's tab: Claude's tab is
  found again by the mark on its page (plan D6).
- The Owner's front window is a private window: Claude's tab opens there, without the Owner's
  logins (Safari's scripting can't tell private windows apart).
- Pages that keep loading or change constantly; very long pages; pages in frames.
- Sites that ignore script-driven clicks (rare): Claude is told nothing changed and can use
  computer control when the screen is on.
- Safari not running: Latchkey starts it.
- A sign-in form the browser filled in: Claude sees the fields, not the password (FR-410). A
  password a page shows as ordinary text without marking the field is ordinary text.

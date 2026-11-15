# Spec 005: Browser control — WHAT and WHY

Status: Approved to build without a review stop (Toni, 2026-10-22); Toni reviews at the end.
Scope: Claude uses the Owner's Safari on the Mac, with the Owner's logins: opens pages, reads
them, follows links, fills in and submits forms, in its own tab and, since 2026-11-03, in any of
the Owner's tabs and windows (Toni: "Claude needs to be able to access my tabs and windows just
like its own").
Out of scope: other browsers (Toni chose Safari, 2026-10-22); clicks, keys, and hovering that
need a real mouse or keyboard (computer control, spec 006).

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

### US5 (P1): Pages that never freeze, one per chat (Toni, 2026-11-15)
1. Given a page shows "Remove item?" after Claude's click, when Claude asks Latchkey, then
   Claude is told what the dialog says and answers it OK or Cancel; nothing waits on the Owner.
2. Given two chats use the browser at once, when each opens pages, then neither loads over the
   other's page.

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
  Latchkey's own browser, saying so (Toni, 2026-11-02: "Switch only when hidden") (2026-11-05: "the
  picture shall be of the same address in Latchkey's own browser" is withdrawn: Latchkey draws
  it from the tab's page as it is, FR-439.)

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
  tab is left as it is), instead of waiting for Safari's time limit (2026-11-15: within 10 seconds,
  and Claude is told the tab may also be busy or paused by Safari and to try again, since a
  busy Bank of America tab was reported as waiting on a dialog it didn't have; and how computer
  control can answer a real one) (Toni, 2026-11-03: "25
  seconds to stall on Claude is too much"; "Answer them, Claude can say OK").

- **FR-433** While Browser is Read & write, Claude shall be able to press keys in the page it
  works in, in a field it names or the one with the focus: Return, Escape, Tab, arrows,
  Backspace, Delete, Home, End, Page Up and Down, Space, single characters, and shortcuts with
  Command, Control, Option, and Shift; the answer shall say what each key did (Toni,
  2026-11-05: "all the safari stuff").
- **FR-434** While Browser is Read & write, Claude shall be able to hover over an element, so
  menus and hints that open on hover open, and the answer shall say how much more shows.
- **FR-435** While Browser is Read & write, Claude shall be able to scroll the page, or a part of
  it that scrolls on its own, up, down, left, right, by an amount, or to the top or bottom, and
  the answer shall say where it is now; reading a page shall list the parts that scroll.
- **FR-436** While Browser is Read & write, Claude shall be able to choose one or several
  options in a list by their text or value, in the page's own lists (`select`) and in lists a
  page builds itself (combo boxes, list boxes, menus); when an option isn't there, the answer
  shall name those there are.
- **FR-437** While Browser is Read & write, Claude shall be able to attach any file on the Mac
  that the Owner's account can read to a file field of the page (also one the page hides behind
  a button of its own) or drop it on a place that takes dropped files; nothing is sent until the
  page's form is. Reading a page shall list its file fields.
- **FR-438** While Browser is Read & write, Claude shall be able to save the file a link names,
  an address, or the page itself (a PDF the tab shows) into the Mac's Downloads folder, with the
  page's sign-in, under the file's own name and never over another file; the answer shall give
  the saved file's path, and the file shall be marked as downloaded from the web, as Safari
  marks its downloads.
- **FR-439** When a picture of the page can't be captured from the screen (the Mac locked, the
  display asleep, the lid closed, no screen permission) or the Owner can see the Safari window,
  Latchkey shall draw the picture itself from the page as it is in its tab (what fields hold,
  what is chosen, how far it is scrolled; never what a password field holds), and say so.
  (Amends FR-423: the picture no longer loads the same address afresh, which lost what Claude
  had typed, and spec 006 FR-509's "under the same screen conditions".)
- **FR-440** The actions of FR-433 to FR-438 shall work as click and type do (FR-413, FR-425 to
  FR-430): in Claude's background tab or the Owner's tab Claude works in, without bringing a tab
  or Safari forward, and in Latchkey's own browser while the Mac is locked; each shall appear in
  the menu's activity (FR-408).
- **FR-441** When Claude opens a page in Latchkey's own browser (FR-420), Latchkey shall first
  take the Owner's Safari cookies again, as they are then: a cookie Safari holds replaces this
  browser's copy of it (same site, name, and path), also one the site took away here, and a
  cookie only this browser holds stays (Toni, 2026-11-14: "copying cookies from real browser
  would always work"; a site had signed Claude out in this browser while Safari stayed signed
  in). Amends FR-420's "as they are when it starts"; FR-421 holds for every copy. (2026-11-15:
  the cookies taken are those of the site the page goes to, when it goes there, and Claude's
  pages share them, as a browser's tabs do: copying all of Safari's 3,500 into every new page
  took over 100 seconds, so pages timed out.)
- **FR-442** While Claude's page is in Latchkey's own browser, Claude shall be able to ask for
  the Owner's Safari cookies to be taken again and its page loaded again, for a page that came
  back signed out after a click or typing (Toni, 2026-11-14: "allow agent to initiate
  real->latchkey browser cookie copy manually"). While Claude's page is in Safari, the answer
  shall say that Safari is already signed in as the Owner, and nothing shall change.
- **FR-443** Every answer that comes from Latchkey's own browser (a page, a script's result, a
  picture) shall begin by saying that it is from Latchkey's own browser and not Safari, that
  the Mac is locked, and that the Owner's open Safari tabs aren't in it (Toni, 2026-11-15: an
  agent there took it for Safari until it closed the page).
  (2026-11-15: "the Mac is locked" is withdrawn from that first line: Claude's pages are in that
  browser whether the Mac is locked or not, FR-444; the line names the page, FR-445.)
- **FR-444** Claude's own pages shall open in Latchkey's own browser (FR-420, FR-421, FR-441,
  FR-442), whether the Mac is locked or not, and never in Safari; Safari shall be used only for
  the Owner's tabs (FR-424 to FR-431). (Toni, 2026-11-15, "Own browser, Claude answers": a page's
  "Remove item?" dialog froze Claude's background Safari tab on Target, and a dialog in a
  background tab can't be read or answered without bringing the tab forward. Amends FR-412 to
  FR-419 and FR-426, whose tab and window of Claude's own in Safari are withdrawn, with the
  Settings choice of FR-412; FR-420's "while the Mac is locked"; and FR-422: that browser is no
  longer closed when the Mac is unlocked.)
- **FR-445** When Claude opens a page without naming one, Latchkey shall open a new page of
  Claude's own and give its short name (like p4k2) in the answer. A call that names a page shall
  read, act in, open an address in, or close that page; a call that names none shall use the one
  page open, and when several are open it shall do nothing and answer with the list of pages
  (each page's name, title, and address, marked as written by websites). (Toni, 2026-11-15,
  "Page names": Claude's apps send every chat's calls over one connection, so Latchkey can't tell
  chats apart; on 2026-11-15 two other chats' pages loaded over the Target cart in Claude's one
  tab.)
- **FR-446** A page of Claude's unused for 30 minutes shall be closed with its cookies (as
  FR-411). At most 10 pages shall be open at once: an eleventh is refused with the list of pages
  and how to close one, so no chat's page is closed for another's.
- **FR-447** Claude shall work in one of the Owner's tabs only in a call that names that tab; a
  call that names no tab shall work in Claude's own page. (2026-11-15, follows from FR-445: one
  chat's tab no longer becomes another chat's. Amends FR-425's "Claude shall keep working in
  that tab until it opens a page, picks another tab, or leaves it unused for 30 minutes".)
- **FR-448** When a page of Claude's shows a confirm or a prompt that Claude's action didn't
  answer in advance (FR-450), Latchkey shall hold it, and the page shall wait, until Claude
  answers it: OK or Cancel, or the text for a prompt. The answer to the call that was running
  then (or else to Claude's next call on that page) shall say what the dialog says and how to
  answer it. An alert shall be dismissed and told, as before (FR-432). (Toni, 2026-11-15: "why
  can't the browser show the pop-up to claude and let it answer?")
- **FR-449** A held dialog Claude hasn't answered within 5 minutes shall get Cancel (a prompt:
  no text), and Claude shall be told so at its next call on that page. Opening another address
  in that page or closing it shall first answer it Cancel and say so. (Toni, 2026-11-15:
  "Cancel after 5 minutes".)
- **FR-450** An answer Claude gives with its action in advance (OK to a confirm, text for a
  prompt) shall also answer the page's dialogs that come up to 5 seconds after that action
  ended, in Claude's own pages only; in the Owner's tabs FR-432 stands (only during the action).
  (Toni, 2026-11-15, "Up to 5 seconds": Target's dialog came after the click had returned, when
  Claude's OK no longer counted. Amends FR-432 for Claude's own pages.)
- **FR-451** The list of tabs (FR-424) shall also list Claude's open pages: each one's name,
  title, and address.
- **FR-452** When a page Claude opens or goes to in Latchkey's own browser is a file that browser
  doesn't show (a PDF, an archive), Latchkey shall not wait for it to load: the answer shall say
  that the page is a file and how to save it, and saving the page (FR-438) shall save that file,
  fetched with the Owner's Safari cookies (live check 2026-11-15: a PDF's address timed out).

## Success criteria

- **SC-401** From the phone, Claude reads a page of a site the Owner is signed in to on the Mac.
- **SC-402** With Browser Read only, no tool that clicks or types appears (test suite).
- **SC-403** From the phone, Claude lists the Owner's Safari tabs and reads one of them, and the
  tab the Owner has in front stays in front (2026-11-03).
- **SC-404** On the Mac, in a background tab, Claude presses keys, hovers, scrolls, chooses
  from lists, attaches a file, and saves a file into Downloads, and the tab the Owner has in
  front stays in front (2026-11-05).
- **SC-405** A page of Claude's that asks to confirm after a click is answered by Claude, not
  frozen; two chats' pages stay apart (unit tests with the real WebKit view; live check
  2026-11-15).

## Edge cases

- A page shows dialog after dialog: each is held in turn; Claude answers them one by one
  (FR-448). A page that loops on dialogs is closed by Claude (FR-449: closing answers Cancel).
- A chat names a page another chat opened (it can see the names in the list, FR-451): it is the
  Owner's own Claude either way, so it works; the names are random so chats don't hit them by
  accident.
- Latchkey restarts: Claude's pages are gone (they are kept only in memory, FR-421); a call
  naming one is told it isn't open.
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
  computer control when the screen is on. The same holds for keys and hover (FR-433, FR-434):
  they reach the page as a script's events, so a page that checks for a real keyboard or mouse,
  or a menu styled to open only under a real pointer (CSS `:hover`), doesn't react; the answer
  says so.
- A file to save that another site serves and the page may not fetch: Latchkey fetches it
  itself with Safari's cookies (FR-438). A file bigger than 50 MB through the page, or 500 MB
  directly, is refused.
- Safari not running: Latchkey starts it.
- A sign-in form the browser filled in: Claude sees the fields, not the password (FR-410). A
  password a page shows as ordinary text without marking the field is ordinary text.

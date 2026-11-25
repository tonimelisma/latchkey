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
  (2026-11-15: Claude shall be told so within the relay's 30 seconds; with 25 seconds for each
  script a call ran, it heard only that the Mac didn't answer.)
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
- **FR-446a** When 10 pages are open and Claude opens another, the page unused longest shall be
  closed for it if no one has used it for 5 minutes; otherwise the new page is refused as in
  FR-446, saying each was used in the last 5 minutes. (Toni, 2026-11-23, "Close the oldest idle":
  on 2026-11-22 pages left by finished chats filled the limit eleven times, and chats then closed
  each other's pages to make room.)
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
- **FR-453** When Latchkey copies Safari's cookies for a site into Claude's pages (FR-441), it
  shall record in Latchkey's log the site, how many cookies it set, the names of the sign-in
  cookies among them, and how long before Safari had last written its cookie file; never a value
  (FR-421) (Toni, 2026-11-15: Target signed Safari out after Claude's page used a copy, and
  nothing recorded what that page did; "do we need further instrumentation").
- **FR-454** When a site replaces, removes, or adds a sign-in cookie in Claude's pages, Latchkey
  shall record in Latchkey's log, once per site for changes made together, which ones, by name,
  and whether each replaced or removed one was still Safari's copy; never a value.
- **FR-455** (Amended 2026-11-24 by FR-474: a page opens in a Safari tab only when Claude asks to
  show it, and the sign-in cookie no longer decides; Toni: "all actions should default to the
  background browser actually, unless the user wants to see whatever's going on". Was:) While the Mac is unlocked, when Claude opens a page of a site the Owner is signed in
  to in Safari (Safari holds a sign-in cookie for it lasting more than a day), the page shall
  open in a new background tab of Claude's at the end of the Owner's front Safari window, with
  the tab in front unchanged, and later calls that name the page shall work in that tab; any
  other site opens in Latchkey's own browser (Toni, 2026-11-15: "when computer is unlocked, if
  it's a site that would require my sign-in, use my real browser. otherwise use your own").
  When Safari has no window, the page shall open in Latchkey's own browser and Claude shall be
  told why (a new window would show on the Owner's screen, Constitution IV). Amends FR-444.
- **FR-456** While the Mac is unlocked, Latchkey's own browser shall take none of Safari's
  cookies (a copy that renews a rotating sign-in signs Safari out: Latchkey's log, 2026-11-15
  19:23:58, Target). Amends FR-441 and FR-442 for that time.
- **FR-457** While the Mac is locked, Claude's pages shall open in Latchkey's own browser with
  Safari's cookies as FR-441 says, though a site may sign the Owner out in Safari (Toni,
  2026-11-15: "signing me out is a side effect, it's still nice to get web access even when my
  laptop is locked"); answers from that browser shall say so.
- **FR-458** When the Mac is unlocked, the copies of Safari's cookies Latchkey's own browser
  took while it was locked shall be dropped before Claude's next browser call, and Latchkey's
  log shall say so. Its pages stay open.
- **FR-459** While the Mac is unlocked, when Claude asks to sign in again in a page of
  Latchkey's own browser (FR-442), the page shall move into a Safari tab of Claude's at the same
  address, under the same name.
- **FR-460** When Latchkey quits, it shall close every Safari tab of Claude's (FR-455), and when
  Claude closes a page whose tab Latchkey can no longer find surely, Latchkey shall forget the
  page and say so, so no tab of Claude's outlives its page (Toni, 2026-11-21: "you've left all
  the browser tabs open"; every install restarts Latchkey).
- **FR-461** When Latchkey opens a Safari tab of Claude's and the site sends it on to another
  address of the same registered site before Latchkey first finds it (eBay's sign-in sent it to
  its check page, 2026-11-22), the tab shall still be Claude's while every other tab of its window
  is as it was when the tab opened, and only then; Claude is never told such a tab is the owner's.
- **FR-462** A page in Latchkey's own browser shall be told it is in a browser window: as big as
  the page plus a toolbar, at the top left of the main screen's free area, as Safari tells its
  pages, never 0×0 at no place on the screen; nothing comes on screen (Toni, 2026-11-22: "change
  the background tab to be more real so this legitimate use case can work. don't do anything
  malicious": Citi turned the sign-in away after its texted code there, and let Safari through).
  Latchkey does not pretend to be Safari beyond its user agent (no stand-ins for Safari's own
  objects or Apple Pay).
- **FR-463** A script Claude runs in a page that uses `return` outside a function, without
  `await`, shall run as the body of a function, as a script with `await` does, in both browsers
  (live 2026-11-22: it failed with "Return statements are only valid inside functions"). Which
  way it runs is decided before it runs, from its syntax alone, and it runs once.
- **FR-464** A link or button inside a closed menu (a closed `<details>`, or what a button marked
  collapsed controls: `aria-expanded` false with `aria-controls`) shall be listed with the
  page's controls, marked "(in a closed menu «<the menu's name>»)", so Claude can click it even
  when the page's own script keeps the menu from opening (GitHub's two-factor page, 2026-11-22:
  "More options" didn't open and its "SMS Code" link was never listed; its list is the second
  kind, hidden by the page's style).
- **FR-467** A page in Latchkey's own browser shall count as visible and get animation frames, as
  a page in a Safari window does, while nothing comes on screen: its window is far off every
  screen, see-through, takes no mouse or keyboard, is in no window list, behind every other
  window, and never brought forward (Chase's sign-in, 2026-11-22: with the page hidden its
  components never started and its code step was blank).
- **FR-466** Controls inside a page's open shadow roots (web components) shall be listed, acted
  on, and typed into like any other, in the page's order (Etsy's sign-in, 2026-11-22: its email
  and password fields were never listed).
- **FR-465** A control's state as the page declares it (pressed, checked, selected, expanded or
  collapsed, from its `aria-` attributes) shall be shown with it, and a change in it shall count
  as a change after a click (Amazon's returns, 2026-11-22: a "Yes" toggle that only became
  pressed read as "Nothing on the page changed").
- **FR-468** A call with an address and no page shall open a new page (FR-445), never load the
  address into the one page open, which may be another chat's (2026-11-22: a Procare sync loaded
  into another chat's claude.ai page, and that chat's next click landed on Procare).
- **FR-469** Calls that name one of the Owner's tabs shall pick it and act in it as one turn, one
  call at a time; a call whose turn doesn't come within 15 s shall do nothing and say another chat
  is working in the Owner's tabs (2026-11-19: another chat's pick came between a pick and a click,
  and a click meant for an E*TRADE tab landed on another chat's Target checkout).
- **FR-470** A script Claude runs in a Safari tab shall run as code in an async function, never
  through the page's `eval`, its value being that of its one expression or last statement, or
  what it returns; which of these the script is shall be decided by a syntax check in Latchkey,
  never by what the page answers (2026-11-22: scripts with await or several statements failed in
  Safari tabs with an AppleScript error, an async arrow's value was lost, and Amex's page
  replaced `eval`). Amends FR-463.
- **FR-471** `browser_look` with an address and `screenshot` shall answer with the new page's
  picture (2026-11-22: only its text came back).
- **FR-472** The list of what is on a page shall include the controls of frames from the page's
  own site (and their text with the page's), links without an address that have words (scripts
  make them buttons), and, first, what an opened menu or dialog shows; past 400 items it shall
  say how many more weren't listed (2026-11-22: Chase's sign-in frame, Citi's Sign Off, Etsy's
  opened menu).
- **FR-473** Typing into a page's rich text editor shall go through the editor as typing does, and
  submit without a form shall send Enter down, press and up (2026-11-23: claude.ai's prompt box
  was emptied and nothing sent).
- **FR-474** Claude's pages shall open in Latchkey's own browser, locked or unlocked, whatever
  sites the Owner is signed in to in Safari. Only when Claude asks to show a page (the Owner asked
  to see what Claude does) and the Mac is unlocked shall it open in a new background tab of
  Claude's at the end of the Owner's front Safari window, as FR-455 said (the tab in front
  unchanged); while locked it shall open in Latchkey's own browser and Claude shall be told
  nobody can watch. Signing in there is as before: a saved sign-in typed by Latchkey (spec 013),
  or the page moved into Safari with sign_in_again (FR-459, FR-1374). The page tool is renamed
  `browser_look` (its behavior changed; open chats are restarted). (Toni, 2026-11-24: "all
  actions should default to the background browser actually, unless the user wants to see
  whatever's going on"; "A show in Safari option", "As today: saved password or Safari",
  "Rename it".) Showing also applies to a site Latchkey signs in to itself: the tab then has
  Safari's own sign-in, as with sign_in_again (spec 013 FR-1374). Amends FR-455, FR-444, and spec
  013 FR-1351 for a page Claude shows.
- **FR-475** When a page in Latchkey's own browser offers a file to save during Claude's own
  action (a link marked to save, often a file the page made itself; or a file the server sends
  as an attachment, or one no page shows, except a PDF, FR-452), Latchkey shall save it into the
  Mac's Downloads folder as Safari does, under the file's own name and never over another file,
  marked as downloaded from the web, and the page shall stay where it was (problem report
  2026-11-24: the page went to the file's address, which ended Claude's script, and nothing was
  saved; Toni: "Save it, like Safari"). A file over 500 MB (or saves running together past it),
  or still arriving after 10 minutes, shall be stopped and nothing kept; a file arriving is
  written under a name of Latchkey's own and gets its name only once complete, so a stopped save
  never removes anyone else's file. A click that started a save shall not also load the link
  (it would save the file twice). A page that shows Claude's page in a Safari tab of Claude's
  (FR-474) saves as Safari does.
- **FR-476** A save the page starts on its own, more than 5 seconds after Claude's last action or
  after Claude opened another page, a save from a frame of another site, and any save past the
  fifth in one action shall save nothing, and Claude shall be told (a page must not fill
  Downloads by itself). The website's file names and addresses shall be quoted in what Claude is
  told, marked as the website's (security review 2026-11-24).
- **FR-477** Claude's next answer from that page shall say what was saved, with the file's path,
  or why nothing was; an answer shall wait for the saves started during Claude's last action,
  at most 20 seconds, and say which are still arriving.

### Real mouse and keyboard in Latchkey's own browser (Toni, 2026-11-25)

Toni: "Can we aim for an approach that looks as much as humans look on browsers, so that it
would actually work since the sites are meant for humans? No complex tricks with JavaScript or
something that actual humans wouldn't do. That would be more brittle." Choices (2026-11-25):
"Real mouse/keyboard events" in Latchkey's own browser; "List what looks clickable"; "Only
Latchkey's own browser" (the Owner's Safari tabs keep script actions); no page-specific tricks
and nothing reaching into a page's framework. The bug behind it: Procare's sign-in
(schools.procareconnect.com, problem reports 2026-11-24 and 2026-11-25) asks "STAFF / PARENT"
with two clickable boxes Latchkey didn't list, and keeps LOGIN disabled until one is chosen, so
the sign-in came back unchanged without a word.

- **FR-478** While Claude clicks in a page of Latchkey's own browser (FR-474), the click shall
  reach the page as a real mouse's does: the element is first scrolled into view (as the browser
  scrolls to an element it moves the focus to), then the view's pointer moves to the middle of
  the part of it that shows, presses, and releases there, so the page gets the browser's own
  trusted events in a mouse's order (pointer and mouse move, over, enter, down, the focus, up,
  click) and the browser does what a click does there (follows a link, sends a form, ticks a
  box, focuses a field). The events go only to that page's view, inside Latchkey's own window
  that is never shown; never to the screen, the Owner's pointer, or another app (Constitution
  IV). Replaces the page script's click there.
- **FR-479** When another element is drawn over the element Claude names at that point, the
  click shall land on what is on top, as a mouse's would, and the answer shall say what it hit
  (its reference, kind and text).
- **FR-480** Typing into a page of Latchkey's own browser shall reach the page as a keyboard
  does: Latchkey clicks the field (FR-478), selects what it holds, as Select All does, when it
  holds something, then presses one key per character, so the page gets keydown, keypress,
  beforeinput, input and keyup for each, trusted, and the browser itself puts the character in.
  A character no key of a US keyboard types (é, an emoji) arrives as text from the Character
  Viewer does (beforeinput and input, without a key). A new line is Enter, a tab Tab; submit
  presses Enter. A list (`select`) takes the option as before (FR-484).
- **FR-481** Pressing keys (FR-433) in a page of Latchkey's own browser shall send real key
  events to the element with the focus, after a click on the field Claude names, or, for a
  button or link Claude names, after moving the focus to it as Tab would; the browser does what
  the key does (Enter sends a form or presses a button, Tab moves the focus, arrows and Page Down
  scroll). Cmd+A selects all, as the Edit menu does, unless the page took the key; copy, cut and
  paste are refused (they would use the Owner's clipboard), and so is every Command shortcut but
  Cmd+A, Cmd+Z, Cmd+Shift+Z and Command with an arrow or Backspace (one the page doesn't take
  would reach Latchkey's own menu: Cmd+Q would quit it; security review 2026-11-25). The answer says the keys pressed and
  where the focus is after them.
- **FR-482** Hovering (FR-434) in a page of Latchkey's own browser shall move that view's own
  pointer (not the Owner's) onto the element's middle, so the page's hover handlers and its CSS
  `:hover` styles apply as under a mouse.
- **FR-483** While Claude acts in a page of Latchkey's own browser (from the start of a call to
  its answer), the page shall count as the focused front window (`document.hasFocus()` true;
  focus and blur as in a front Safari window); between Claude's calls it shall count as a window
  behind another app's, as a Safari window does then. Why not always: a password field focused
  in a window that counts as the front one turns on macOS's secure keyboard entry for the whole
  Mac, which would get in the Owner's way for as long as the page sat there (Constitution IV).
- **FR-484** A click on a list (`select` showing one line), a colour field, or a date or time
  field in Latchkey's own browser shall not be sent as a mouse click (its menu would hold
  Latchkey up until answered, and a colour panel would open on the Owner's screen): Claude is
  told to use select, or type for a date or time field; keys that open a list's menu (arrows,
  space, Enter while such a list has the focus) are refused the same way. Choosing in such a list
  (FR-436) stays the page's own change of choice (with input and change events), as choosing from
  its menu gives. A file field still takes files with attach (FR-437).
- **FR-485** Each step of a real action (a click, a key) shall wait until the page has taken its
  events, at most 10 seconds a step (Constitution II), and then, as before, for a page it opens.
- **FR-486** The list of what is on a page (both browsers) shall also list what a person sees as
  something to click: a visible element drawn with the pointing-hand cursor where the element
  around it isn't, or with a click handler of its own (`onclick`), that isn't already listed, is
  not inside a listed control and holds none, as kind "clickable" with its visible text, and
  its state where it shows: the page's declared states (FR-465) and "selected", "active" or
  "checked" when its class names say so (Procare's STAFF and PARENT, 2026-11-25).
- **FR-487** In the Owner's Safari tabs (FR-424 to FR-431), actions shall stay page scripts
  (real events there would reach a window the Owner may be using, Constitution IV), but typing
  shall give each character keydown, keypress, beforeinput, input and keyup in a keyboard's
  order (it gave input before keydown, and no keyup).
- **FR-489** Because a real click or key lets a page do what only a person's gesture allows,
  Latchkey's own browser shall keep the Owner's clipboard out of the page's reach (the page's
  clipboard functions refuse; its copy, cut and paste commands do nothing), play no sound
  (its media stays suspended), and refuse a click that would land on a list, colour or date
  field or its label (FR-484); when the Owner's clipboard changed during an action all the
  same, the answer says so (security review 2026-11-25; Constitution IV).
- **FR-488** No action shall use code for one site, or reach into a page's framework (React's
  value tracker or its handlers): pages get what a person's mouse and keyboard give them (Toni,
  2026-11-25).

Amends FR-402, FR-433, FR-434 and FR-440 for Latchkey's own browser, and the edge case of sites
that ignore script-driven clicks; and FR-464 there: an element in a closed menu stays listed and
marked, but a mouse can't reach what doesn't show, so a click on it says to open the menu first
(the menu's button now gets a real click, which GitHub's "More options" didn't get from a
script).

Amended by spec 013 FR-1350 to FR-1355 (Toni, 2026-11-21): for a site Latchkey holds a saved
password for, while Sign-in is On, FR-441, FR-442 and FR-457 copy none of Safari's cookies (nor a
wider domain's that would reach it), FR-455 and FR-459 keep the page in Latchkey's own browser,
and FR-458 keeps Latchkey's own sign-ins; Latchkey signs in there itself, and uses Safari's
sign-in as these rules say only where its own can't finish.

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
- Sites that ignore script-driven clicks: in Latchkey's own browser clicks, keys and hover are a
  real mouse's and keyboard's (FR-478 to FR-482). In the Owner's Safari tabs they stay a
  script's events, so a page that checks for a real keyboard or mouse, or a menu styled to open
  only under a real pointer (CSS `:hover`), doesn't react there; the answer says so, and Claude
  can open the page in its own browser or use computer control when the screen is on.
- A file to save that another site serves and the page may not fetch: Latchkey fetches it
  itself with Safari's cookies (FR-438). A file bigger than 50 MB through the page, or 500 MB
  directly, is refused.
- Safari not running: Latchkey starts it.
- A sign-in form the browser filled in: Claude sees the fields, not the password (FR-410). A
  password a page shows as ordinary text without marking the field is ordinary text.

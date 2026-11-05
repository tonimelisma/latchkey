# Tasks 005: Browser control

- **T401** ✅ Tests first (WebKit view), then the page scripts: read with references, click, type,
  choose, submit. *FR-401, FR-402, D3.*
- **T402** ✅ Tests first (stand-in runner), then the Safari driver: own window, tabs, back,
  waiting, closed window, missing setting. *FR-403, FR-406, D2.*
- **T403** ✅ Tools, levels, activity. *FR-404, FR-405, FR-407, FR-408, D1, D5.*
- **T404** ✅ Setup steps: Automation for Safari, the JavaScript setting with Check. *FR-406, D4.*
- **T405** ✅ Tests first, then only http and https addresses open (security scan, 2026-10-24).
  *FR-409, D2.*
- **T406** ✅ Tests first (stand-in Safari with windows and tabs, WebKit view for the mark), then
  Claude's page as a background tab in the Owner's window, the Settings choice, finding the tab
  again, screenshot and back, idle close (2026-10-29). *FR-403, FR-411 to FR-418, D6.*
- **T407** Tests first (stand-in Safari timed like real Safari, WebKit view, paging), then the
  note taken in the script's own run, the clicked link's and back's address, the acting script's
  short wait for the note, and answers within Claude's result size with the offset named
  (2026-10-29). Checked against real Safari with `macos/scripts/safari-check.sh`. *FR-403,
  FR-405, FR-418, D3, D6.*
- **T408** Tests first (stand-in Safari with the Owner's windows and tabs, the tools' answers),
  then the list of every tab, picking one of the Owner's tabs and working in it as in Claude's
  own (read, back, picture, click, type, script, close), the check before each use, back to
  Claude's own tab at the next page, the locked answer (Toni, 2026-11-03). Checked against real
  Safari with `macos/scripts/safari-check.sh`. *FR-424 to FR-431, D8.*
- **T409** Tests (WebKit view for every page script, Latchkey's own browser, the stand-in Safari
  for the tools), then keys, hover, scrolling, lists, attaching files, saving files, and
  pictures drawn without the screen (2026-11-05). Checked against real Safari with
  `macos/scripts/safari-check.sh` on a local test page. *FR-433 to FR-440, D10.*

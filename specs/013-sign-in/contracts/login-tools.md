# Contract: the Sign-in tools (spec 013)

Both exist only while the Owner's Sign-in setting is On (FR-1340). Answers are text only.

## logins_find (read-only)

- Title: "Find Saved Sign-ins". Annotations: readOnly true, openWorld false.
- Input: `site` (optional text): only sign-ins whose site is, contains, or covers it.
- Answer: when the copies were taken in; the totals ("N sign-ins for M sites;" then "none has a
  verification code in Passwords." or "K with a verification code, marked below; the rest have
  none."; feedback report 2026-11-21); then one line per sign-in, `site — user name` plus "(has a
  verification code)" when it has one. Never a password or code. With none:
  "Latchkey holds no sign-ins yet. The Mac's owner can hand them over from Latchkey's menu →
  Export Passwords to Latchkey…".

## logins_sign_in (write)

- Title: "Sign In on a Page". Annotations: readOnly false, destructive false, idempotent false,
  openWorld true. Limit 30 s.
- Input: `page` (Claude's page, like "p4k2", as browser_read named it; required when several are
  open), `user` (optional: the user name to sign in as, from logins_find).
- Works in Claude's own pages only (Latchkey's own browser, or a Safari tab of Claude's), never in
  the Owner's tabs.
- Answer: the outcome in plain words, then the page as browser_read shows it:
  - "Signed in to <site> as <user>."
  - "<site> now asks for a verification code Latchkey doesn't hold (sent by text or email?)."
  - A code the site texts (FR-1360, FR-1361) is filled without a word of it. Inputs `code` (a
    code Claude read in the owner's email with its own tool, 4 to 10 letters or digits) and
    `no_email_access` (true: Claude has no email tool; Latchkey reads Apple Mail), FR-1364,
    FR-1365. When no code came within 20 s (45 s with `no_email_access`), not an error, no
    fallback until 2 minutes have passed: "<site> asks for a verification code it sent to the
    owner, by text or email, and none has reached Messages on this Mac yet. Can you read the
    owner's email with a tool of your own …?" with the three ways on (pass `code` and archive
    the email; only without an email tool, `no_email_access`; for a text, call again). With
    `no_email_access`: "… hasn't reached Messages or Apple Mail on this Mac yet. Call … again
    with no_email_access true …". After a sign-in with `code`: "Latchkey marks the email with
    that code read and archives it in Apple Mail." or, when Mail doesn't have it, "Now mark the
    email with that code read and archive it with your email tool." (FR-1366).
  - "<site> shows a check Latchkey can't answer (a captcha or a new-device check)." Only a
    challenge the page shows counts: hidden reCAPTCHA frames from ad scripts and the invisible
    reCAPTCHA badge don't (live check 2026-11-21, homerecording.com, a sign-in that had worked).
  - "<site> refused the sign-in: «page's words». One more try is allowed." / "…Latchkey won't
    try it again until the owner exports from Passwords again."
  - In Latchkey's own browser, after a code it doesn't hold, a check, or a refusal on a site it
    signs in to itself (FR-1352), the line goes on: "Latchkey's own sign-in couldn't finish on
    <site>, so the owner's Safari sign-in is used there instead, until the owner exports from
    Passwords again:" then, locked, "this page took a copy of Safari's cookies for it … and
    opened <site> again." (or "…but loading it again didn't work: read it again with browser_read."),
    unlocked, "the page moved into a Safari tab of Claude's, signed in as the owner if Safari
    is." (or "…couldn't move into Safari (Safari has no window open), so it stays here.").
  - The first line of every answer from Latchkey's own browser on such a site (FR-1355): "…
    Claude's page "<name>", with Latchkey's own sign-in for <site>, not a copy of Safari's, so the
    owner's Safari stays signed in (if the page asks to sign in, logins_sign_in signs in)."
    `browser_read sign_in_again` there: "Latchkey signs in to <site> itself … call
    logins_sign_in with page "<name>"; if that can't finish, it uses the owner's Safari sign-in
    instead."
  - Errors (isError): no sign-in for the page's site (with the sites it does hold, at most 20);
    several user names (listed: call again with user); not https; the Owner's tab; no page.

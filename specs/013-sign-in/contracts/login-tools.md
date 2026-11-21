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
  - "<site> shows a check Latchkey can't answer (a captcha or a new-device check)." Only a
    challenge the page shows counts: hidden reCAPTCHA frames from ad scripts and the invisible
    reCAPTCHA badge don't (live check 2026-11-21, homerecording.com, a sign-in that had worked).
  - "<site> refused the sign-in: «page's words». One more try is allowed." / "…Latchkey won't
    try it again until the owner exports from Passwords again."
  - Errors (isError): no sign-in for the page's site (with the sites it does hold, at most 20);
    several user names (listed: call again with user); not https; the Owner's tab; no page.

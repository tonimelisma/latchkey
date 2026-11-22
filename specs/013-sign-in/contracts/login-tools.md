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

## logins_fill (write; replaces logins_sign_in, 2026-11-22)

Toni, 2026-11-22: "Fill-only tool". Latchkey types; Claude reads the page and decides (FR-1371).

- Title: "Type a Saved Sign-in". Annotations: readOnly false, destructive false, openWorld true.
  Limit 30 s (one fill and one press; nothing waits for a code).
- Input: `page` (Claude's page, like "p4k2"), `field` (required: the field's reference from
  browser_read, like "e18"), `fill` (required: `user`, `password`, or `code`), `press` (the
  button's reference to press right after; required for `password` and `code`), `user` (which
  saved user name, when there are several), `code` (a code Claude read in the owner's texts or
  email, 4 to 10 letters or digits; with `fill` `code`).
- What goes where (FR-1372): `password` only into an `input type=password` that isn't a
  one-character box; `user` only into a text, email, or phone input; `code` into a password input,
  across one-character boxes starting at `field`, or into a text, number, or phone input marked or
  named for a code (one-time-code, numeric, code, otp, verif, PIN, digit, 2FA, token, security);
  else "… (it is a text (not a code) field)". A password or code Latchkey typed is shown as •••
  wherever it appears in the answer. A Passwords code a refused field didn't take stays for the
  next call.
- Where the code comes from (FR-1375): the code `code` Claude passed (read by Claude from the
  owner's texts with messages_find and messages_read, or email with its own tool or mail_find and
  mail_read), else the current code of the sign-in's generator from Passwords (each 30-second code
  once, counted once typed). Neither: an error, nothing typed: "Latchkey holds no code generator
  for <site> in Passwords, so nothing was typed. Read the code yourself (…), then call again with
  code." After a code Claude passed: "If it came by text or email, delete that text
  (messages_delete) or archive that email now."
- The codes experiment (FR-1376): `code_from` (`text` or `email`, with `fill` `code`, without
  `code` or `check_code`): Latchkey finds the site's newest unused code since the password it
  typed (10 minutes, else the last 3) and types it; the answer never holds it: "Typed the code
  from the owner's <texts|email> into <field>, then pressed <press>. Latchkey deleted the text it
  came in." (or "archived the email it came in", "will … when the Mac is next unlocked",
  "couldn't …: <why>", "<Messages|Mail> isn't Read & write in Latchkey's settings, so … stays").
  None yet (no error): "No <text|email> with a code for <site> has come since HH:MM (<n> seconds
  ago), so nothing was typed. If the site said it sent one, wait as long as you like and call
  again." Messages or Mail Off: an error. `check_code` true (with `code`): typed only if a text or
  email for the site since then holds exactly that code, else an error "No text or email for
  <site> since HH:MM holds that code, so nothing was typed."; then cleaned up as above. Choices:
  research.md "Codes experiment".
- Answer: "Typed the saved <user name|password> for <site> (<user>) into <field>[, then pressed
  <press>]." / "Typed <the code from Passwords|the code you passed> into <field> (<n> boxes),
  then pressed <press>." Then the page as browser_read shows it (with
  password and code fields hidden). Never "signed in", "refused", or any judgement of the page.
- Errors (isError, nothing pressed): no sign-in for the page's site (the sites it holds, at most
  20); several user names (listed); not https; the Owner's tab; no page; the field missing; the
  wrong kind of field ("e12 isn't a password field: it is a text field"); the field didn't hold
  what was typed (a page that rewrites input); `press` missing for password or code.

## browser_read sign_in_again on a site Latchkey signs in to itself (FR-1374)

- Unlocked: the page moves into a background Safari tab of Claude's at the same address, under the
  same name; the answer is that tab's page, as for any other site (FR-459).
- Locked: "Latchkey signs in to <site> itself in its own browser and takes none of Safari's
  sign-ins for it. Safari's own sign-in can be used once the Mac is unlocked: then call
  browser_read with sign_in_again again."
- The first line of every answer from Latchkey's own browser on such a site (FR-1355): "…
  Claude's page "<name>", with Latchkey's own sign-in for <site>, not a copy of Safari's, so the
  owner's Safari stays signed in (if the page asks to sign in, type the saved sign-in with
  logins_fill)."

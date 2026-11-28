# Spec 014 research: how problem reports reach the developer

2026-11-23, with Toni. What happened before: spec 001 FR-690 to FR-695 and `docs/STATUS.md`,
"Feedback reports, 2026-11-17 to 2026-11-23".

## Who owns what (Toni: "I only own the dev agent"; "anyone can host their own latchkey relay. I
## don't think I should have access to all of them")

| Party | Owns | Must never |
|---|---|---|
| User | Claude chats, machines, account on a relay | — |
| Relay operator | The relay (often the user) | Read a shared report, or hold credentials into the developer's systems |
| Developer | The intake and the development agent | Reach any relay, or see a report its user didn't share |

So a report crosses into the developer's hands only when its user opted in, through a place
the developer owns that anyone may write to and only the developer can read.

## Options weighed

| Option | Verdict |
|---|---|
| Reports stay on the user's Mac (as built) | Rejected: the developer sees only his own; reading needs the Mac online, shell approvals, and can't mark handled (2026-11-23) |
| Email to the developer, encrypted | Rejected (Toni: "I'm not sure email is a serious solution") |
| A mailbox on the hosted relay the developer reads | Rejected: confuses the relay operator with the developer; the developer has no access to relays |
| A private GitHub repository's issues | Rejected: whoever files needs a token that writes to the developer's repository; shipped in a relay, it leaks |
| Public GitHub issues, encrypted | Rejected: the same token problem, and public metadata |
| A Google Form into the developer's Sheet | Rejected: an unofficial way of posting, open to spam |
| The user's own account inbox, plus sharing | Rejected (Toni: "why are they retained for the user at all? they are sent to me") |
| **An intake the developer runs; relays send encrypted reports of opted-in users** | **Chosen (Toni, 2026-11-23: option 2, "a serious design")** |

## Choices made

- **Hosting** (Toni): a small VM running the intake in Docker, the relay's shape (Go, SQLite,
  one container), so a fork's developer can run their own.
- **Encryption** (Toni: Go's own crypto; "for golang, I'm sure there's a ready solution"): the
  standard library's `crypto/hpke` (RFC 9180, Go 1.26+), one-shot `hpke.Seal` on the relay and
  `hpke.Open` on the developer's side. Suite, decided here as a low-level detail: KEM
  `MLKEM768X25519` (a post-quantum hybrid, as reports may wait a long time), KDF `HKDFSHA256`,
  AEAD `ChaCha20Poly1305`; `info` names the format version ("latchkey-report-v1"). Options
  weighed: X25519 alone (smaller keys, no post-quantum protection), AES-256-GCM (as good; ChaCha20
  is constant-time everywhere in software). No new dependency.
- **Default** (Toni): sharing Off.
- **Nothing kept for the user** (Toni): a report goes to the intake and stays there until the
  developer's agent dispositions it.

## Details decided here (low-level)

- **Proof of work**: the sender finds a nonce so that SHA-256 of (the report's hash, the UTC hour,
  the nonce) starts with 20 zero bits, about a second of one CPU; the intake checks it in
  microseconds and accepts the current or previous hour. Options weighed: none (free flooding),
  a registered key per relay (free to make many), CAPTCHAs (no human there).
- **Rate limit**: a token bucket per sending address in memory (standard library only), 60 an
  hour by default.
- **Reporter tag**: HMAC-SHA256 of the account id under a secret of the relay's own, first 8
  bytes, hex: stable per account on one relay, meaningless elsewhere.
- **What goes in a report** is Claude's judgment, not the relay's (Toni, 2026-11-23: "the user's
  agent needs to be trusted not to submit anything dangerous"). Masking with patterns on the relay
  was proposed and withdrawn: deterministic matching misses some secrets and mangles harmless
  text, and it would be the relay judging content (Constitution X). The tool's description says
  what stays out.

## Answered by Toni (2026-11-23)

- Self-hosted relays forward to Latchkey's developer by default; the user's opt-in decides
  (FR-1415). An operator can add a block (FR-1415a).
- The intake runs on the developer's own server at `latchkey-feedback.melisma.net`; the hosted relay keeps its name
  (FR-1426). Weighed and dropped the same day: moving the relay to a hard-to-guess name. It would
  have needed a wildcard certificate (else the name is in the public certificate logs within
  minutes), so a DNS token stored on the server; one hard switch (passkeys, connector, pairing,
  mail's own name); for one extra layer against bots that scan for new flaws, while sign-in is
  what secures the relay.

## Decided here: repository layout

Inside the relay's Go module: `relay/reports` (the format both sides share: fields, sealing,
proof of work), `relay/internal/intake` and `relay/cmd/latchkey-intake` (the intake), and
`relay/cmd/latchkey-reports` (the developer's command), with its own image built by the relay's
image workflow from `relay/Dockerfile.intake`. Options weighed: a top-level `intake/` module (the
first plan: a cleaner split, but the report format would have been copied, or reached across
modules with replace directives that break the Docker builds), or a separate repository (a second
place for sessions, CI, and specs). One module keeps the format in one place and gives the
intake the relay's lint, security checks, tests, and signed images; the relay's own binary
doesn't include the intake.

- At disposition the report is deleted, nothing kept; git is the history (FR-1424).

## Everything for that chat (2026-11-25)

Toni's product choices (AskUserQuestion, 2026-11-25): "Everything for that chat"; "Same for
everyone, said plainly"; "Always record, memory only"; "5 MB, screenshots included"; "Hidden
world". The rest was decided here (low-level, CLAUDE.md "Toni decides"):

- **Which calls are "that chat"**: (a) the relay's trace by connector session id, plus earlier
  sessions that used one of its pages (chosen: Claude opens one session per conversation, and a
  page name is made for one chat, so a chat idle 30 minutes that continues on a new session is
  still joined; deterministic, no guessing); (b) everything from the same Claude app in a time
  window (kept only for clients without sessions: it mixes chats); (c) ask Claude to list its
  calls (rejected: what was missing was exactly what Claude didn't see).
- **How the relay asks a machine**: (a) a new message type pair (rejected: an older app or relay
  closes the connection on an unknown type, so both must be deployed in order and need
  fallbacks); (b) an ordinary `call` of a tool no machine may list, announced by a hello feature
  (chosen: deadlines, cancel, progress and the frame limit already work; only machines that
  announce it are asked).
- **The relay's log**: (a) read the relay's process log (rejected: it is stdout, mixed across
  accounts, and kept by the host); (b) a ring per account in memory of lines tagged with the
  account, plus the account's trace events (chosen; nothing new on disk).
- **Recording in Latchkey's own browser**: (a) the page's own functions wrapped (console, fetch)
  (rejected by Toni: a site can notice it, and it changes behaviour); (b) a WKContentWorld of
  Latchkey's own with a script message handler only that world has, and the navigation delegate
  for loads (chosen). What WebKit gives there: resource timing entries (address, kind, status
  where `responseStatus` is filled, timing, size), `error` (also failed loads, in the capture
  phase), `securitypolicyviolation`, `visibilitychange`, each only when the browser made it
  (`isTrusted`), at most 50 a second; not console lines, not the method of the page's scripted
  requests, and not failed promises (`unhandledrejection` reaches only the page's own world:
  the test on GitHub's macOS runner saw none, 2026-11-25).
- **Addresses in records**: query values replaced by "…" and fragments and user names dropped,
  names kept (sign-in links, tokens and ids live there); the page's own address the same. The
  chat's calls keep what Claude itself sent and got.
- **Page source**: a clone of the DOM, read in the hidden world, with every field's value, every
  textarea, every editable area, every inline script's body, token-like meta values and
  token-like attributes blanked (security review 2026-11-25); button labels stay.
- **Blanking in the relay**: the values Claude passed under a secret's name (code, password,
  pin, any name with token, secret, password, cookie, credential, api key), any argument of 4 to
  8 digits, and credentials written into text (`Bearer …`) are replaced everywhere in the
  report, except where a byte replaced would break what isn't text (a picture's data, the relay's
  own times and ids), decided by place in the report, not by key name (security review
  2026-11-25).
- **Typed secrets**: in Latchkey's own browser, a read in the hidden world before typing
  (skipped while a dialog is held or a file is shown, 2 s at most) says whether the field is a
  password, one-time-code or card field; the value is kept in the page's record and sent as the
  part's `secrets`, which the relay uses for blanking and removes before sealing. In Safari no
  read (it would run through the tab's action script and take the action's navigation note):
  every text typed there is blanked instead, failing closed (security reviews 2026-11-25).
- **Older intakes**: an intake from before 2026-11-25 refuses over 64 KB with 413; the relay
  keeps a small version sealed beside each report and sends it then, so no report is lost while
  the intake's new image rolls out.
- **Size**: oldest first, as Toni chose; the newest call with a picture stays the longest.

## Reports without a session (2026-11-27)

The three reports of 2026-11-26/27 carried no calls, no pages and under a minute of log: claude.ai
and Claude Code now use the MCP protocol without sessions (2026-07-28), and the relay took no calls
for a report without one, though FR-1441 named a fallback. Details decided here (low-level):

- **Which calls**: the account's trace lines of the last 2 hours with no session and the same
  client name as the `feedback` call. Options weighed: the OAuth grant (the trace doesn't record
  it, and one app's chats share a grant anyway), every call of the account (mixes Claude Code
  with claude.ai), the time span only (as wrong as the client name, and less precise). The
  report's `chat.how` says other chats of the same app may be among them.
- **Span**: from the chat's first call, and at least 15 minutes before the report (FR-1442a), so a
  report about a restart or a reconnect shows it even when the chat made few calls. Longer spans
  only fill the 5 MB with other chats' lines; the fit drops the oldest first anyway.
- **Relay-wide lines**: marked at the call site (`reportlog.RelayWide`); the ring keeps only the
  message and a `version` attribute of such a line, so a later caller can't put an account, a
  machine or an address into every account's report.

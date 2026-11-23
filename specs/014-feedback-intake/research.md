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
- The intake runs on pilvi at `latchkey-feedback.melisma.net`; the hosted relay keeps its name
  (FR-1426). Weighed and dropped the same day: moving the relay to a hard-to-guess name. It would
  have needed a wildcard certificate (else the name is in the public certificate logs within
  minutes), so a Cloudflare token stored on pilvi; one hard switch (passkeys, connector, pairing,
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

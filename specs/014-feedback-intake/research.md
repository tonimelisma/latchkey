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
- **Masking**: before sealing: 4 to 8 digits next to "code", "PIN", "OTP" or "verification"; any
  run of 8 or more digits (spaces and dashes allowed); strings that look like keys or tokens
  (long base64 or hex). Replaced by "[masked]". Masking is best effort; the opt-in screen says so.

## Still for Toni

- Self-hosted relays: send to Latchkey's developer by default, or only once their operator sets
  an intake (FR-1415).
- At disposition: delete the report, keeping only its outcome, or keep it for a time (FR-1424).
- Where the intake's VM runs and its address (needs Toni's account).
- Repository layout: a new top-level folder `intake/` (proposed), or inside `relay/`.

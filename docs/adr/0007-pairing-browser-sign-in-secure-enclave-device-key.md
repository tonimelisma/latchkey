# 0007. Pairing: browser sign-in, Secure Enclave device key

- Status: accepted
- Date: 2026-10-19
- Alias: plan 001 D6 (`specs/001-core/plan.md`, "D6. Pairing: browser sign-in, Secure Enclave device key")

## Context and problem

Decision D6 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-050, FR-051, FR-052, FR-054, FR-054a, FR-054b, FR-081.
The design it belongs to: [design/core.md](../design/core.md).

## Decision

Serves FR-050, FR-051, FR-052, FR-053, FR-054; Constitution IV.
- The app opens `ASWebAuthenticationSession` (Apple's sign-in window; it uses the default browser
  when that browser supports it, else Safari, and closes itself on the callback) to `/pair`; the
  Owner signs in on the one email-first page; the relay redirects to
  `latchkey://paired?code=...&relay=...`; the app exchanges the code. The session's completion
  handler runs off the main thread. That callback is trusted and needs no dialog.
- A `latchkey://paired` link that reaches the app any other way (the system's URL handler, from
  another browser, with or without a pairing in progress) is used only after the Owner confirms
  an alert titled with the relay's host, saying which account email that relay claims, whether
  the relay differs from the paired one (or, unpaired, the hosted relay the app suggests), and
  that it replaces the current pairing if there is one (FR-054). The app gets the email from `POST /pair/preview`, which looks the code
  up without using it (contracts/agent-protocol.md "Pairing"); if that fails the alert says the
  link expired and has no Connect button. Confirming cancels a sign-in window that is still open.
  A link carrying the code the sign-in window just delivered is ignored (already used).
- One such link is handled at a time: while one is being looked up, shown, or exchanged, others
  are dropped (and noted in the log), so links can't stack dialogs or make the app send a burst
  of lookups (FR-054a). A link naming `http://localhost` or `http://127.0.0.1` is accepted only
  in Debug builds; in the installed (Release) app it counts as incomplete, so a link can't make
  the app talk to whatever listens on a local port. The relay field in setup still takes them
  (FR-054b, FR-081).
- The app's log (`log show`) carries relay addresses only as private data (a hash), never in
  the clear.
- During the exchange the app registers a P-256 public key whose private key lives in the Secure
  Enclave (CryptoKit). No bearer secret leaves the Mac.
- The pairing (relay address, device ID, and the key's Secure Enclave blob) is one generic
  password item in the Owner's login keychain, created by the app, so other programs can't read
  or change it without the Owner's password. User defaults, which any program running as the
  Owner can change without a permission, hold none of it: a relay address there pointed the app
  and its privacy permissions at another relay (security scan, 2026-10-24). Reads look only in
  the login keychain (opened by its path), never prompt, and refuse more than one match; the
  address must still be https (http only for localhost). An older version's pairing (address and
  ID in user defaults, key in its own item) is never used, only removed: the Owner pairs again.
  0.8.4 moved it instead and lost the only one (the maintainer's) when its stricter read couldn't see the
  old key; a review then found that any retried move leaves a window for planted settings, and
  no other installs exist, so the move was dropped (2026-10-24). Capability levels stay in user
  defaults: they only limit what the paired Claude can use.
- WebSocket authentication: the relay sends a nonce; the app signs it with the device key
  (contracts/agent-protocol.md).
- Pairing while a Mac is paired shows the current Mac's name and asks to replace it (FR-053);
  confirming revokes the current Mac before the new one is created.
- Revocation deletes the device's public key and closes its socket with code 4002. It starts from
  the web account page, or from "Disconnect" in the app, which sends `goodbye` with reason
  `user_disconnected`; the relay treats that reason as a revocation.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/PairingTests.swift`
- `relay/internal/account/account_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

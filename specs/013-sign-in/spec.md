# Spec 013: Signing in by itself — WHAT and WHY

Status: Draft for Toni's review (started 2026-11-20). No plan, tasks, or code until Toni approves.
Scope: Latchkey's own browser signs in to sites by itself with copies of the Owner's existing
passwords and passkeys, which the Owner hands over once from Apple's Passwords app. Latchkey,
never Claude, fills in the secret; Claude never sees it.
Out of scope: registering new passkeys of Latchkey's own on the Owner's accounts (Toni,
2026-11-20: "that'll mess up everything"); a live link to Apple's Passwords (none exists:
`research.md`); other password managers; creating accounts or changing passwords.

Research: `research.md`.

## Problem

While the Mac is locked, Claude's pages open in Latchkey's own browser with copies of Safari's
cookies (spec 005 FR-457). When a site's sign-in has expired in Safari, or the site signs
Latchkey's copy out, Claude reaches a sign-in page and can go no further: the Owner is away, and
nothing on the Mac can sign in for them. Apple's Passwords app has no interface another app can
read, so the only way in is a copy the Owner hands over themselves.

## User stories

### US1 (P1): Hand over my sign-ins once
1. Given I open Passwords and choose to export to another app, when I pick Latchkey and approve
   with Touch ID, then Latchkey keeps a copy of what I exported and says how many sign-ins it
   now holds.
2. Given I later add or change a password, when I export that item again, then Latchkey's copy
   is replaced by the new one.

### US2 (P1): Claude gets past a sign-in page while I'm away
1. Given the Mac is locked and Claude reaches a site's sign-in page in Latchkey's own browser,
   and Latchkey holds a sign-in for that site, when Claude asks Latchkey to sign in, then
   Latchkey fills in and sends the sign-in itself and Claude continues on the signed-in page.
2. Given the site asks for a passkey Latchkey holds, then Latchkey answers it itself.
3. Given Latchkey holds no sign-in for the site, then Claude is told so at once, in plain words.

### US3 (P1): Claude never holds my secrets
1. Claude never sees a password, a passkey, or a code: not in a page it reads, not in an answer,
   not in Latchkey's log or traces.

### US4 (P1): Off means gone
1. Given signing in is Off, then no sign-in tool or mention exists for Claude (Constitution III).
2. Given I remove Latchkey's copies, then they are gone from the Mac, and deleting the app
   leaves none behind (Constitution IV).

## Requirements

Numbers FR-1300 onward. Draft; the choices marked below are Toni's.

- **FR-1300** Latchkey shall accept sign-ins only through Apple's export to another app, which
  the Owner starts and approves on the Mac themselves.
- **FR-1301** Latchkey shall keep its copies only on the Mac, encrypted by the Mac's Keychain,
  never sent to the relay, never logged, traced, or shown to Claude.
- **FR-1302** Latchkey shall fill a sign-in only into a page whose address belongs to the site the
  sign-in was saved for. [NEEDS CLARIFICATION: exact site matching rule]
- **FR-1303** When Latchkey holds no sign-in for the page's site, the answer shall say so at once.
- **FR-1304** [NEEDS CLARIFICATION: what comes over: passwords, passkeys, verification codes]
- **FR-1305** [NEEDS CLARIFICATION: where Latchkey signs in: its own browser only, or also
  Claude's Safari tabs]
- **FR-1306** [NEEDS CLARIFICATION: Claude asks to sign in, or Latchkey signs in whenever it
  meets a sign-in page]
- **FR-1307** [NEEDS CLARIFICATION: whether Claude may list which sites Latchkey can sign in to]
- **FR-1308** [NEEDS CLARIFICATION: its own capability in Latchkey's menu, or part of Browser]

## Success criteria

- With the Mac locked and the lid closed, Claude signs in to a site whose Safari sign-in has
  expired, with no help from the Owner, and finishes the task.
- No secret appears in anything Claude, the relay, the log, or the traces receive (a test
  searches them for every imported secret).

## Edge cases

- A site that sends a code by text or email after the password (two-step sign-in).
- A site that asks for a new-device confirmation, or locks the account after failed tries.
- A sign-in form inside a frame from another site.
- A lookalike address of a real site.

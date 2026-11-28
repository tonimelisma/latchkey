# 0147. The one-touch export (FR-1301, FR-1306)

- Status: accepted
- Date: 2026-11-21
- Alias: plan 013 D3 (`specs/013-sign-in/plan.md`, "D3. The one-touch export (FR-1301, FR-1306)")

## Context and problem

Decision D3 of spec 013's plan (Signing in); requirements in
[requirements/sign-in.md](../requirements/sign-in.md). Requirement IDs it cites: FR-1301, FR-1306, FR-1307.
The design it belongs to: [design/sign-in.md](../design/sign-in.md).

## Decision


`PasswordsExport` drives Passwords through Accessibility (the permission setup already asks for):
open Passwords (`NSWorkspace`, it comes to the front because the Owner clicked); wait up to 2
minutes for File → Export All Passwords to File… to be enabled (it is while Passwords is unlocked:
the Owner's Touch ID); press it; press the confirmation's Export button; in the save panel, set
a unique file name, open Go to Folder (Command-Shift-G), put the import folder's path in its
field, Return, and press Save; then D2 takes the file. Each step looks for its element by role
and title for up to 10 s; anything unexpected stops the export, cancels the panel, leaves
Passwords as it is, and says which step. Passwords is quit afterwards only if Latchkey started it.
Each step's name shows in the menu and Settings while it runs; a stop also comes as a
notification, and a finished import sends its own (D2).

Found on the first real run (2026-11-21), and how it works since:
- Latchkey looks only in Passwords' dialogs (the sheets on its windows, and windows that aren't
  standard ones), never in the main window: with 1,045 passwords that window is about 4,500
  Accessibility elements, and one look through it took 85 s. A sheet is about 14 elements and
  0.07 s. Each Accessibility call has a 1 s limit.
- The save panel runs in a process of its own (`openAndSavePanelService`), so keys sent to
  Passwords' process alone (`CGEvent.postToPid`) never reach it: Go to Folder didn't open and the
  export stopped. The two key presses (Command-Shift-G, Return) are posted as the keyboard posts
  them, and only while Passwords is in front (brought back once if not); otherwise the export
  stops and cancels the panel. Tried on TextEdit's panel, the same one: it opens and saves where
  told.
- No file left behind (FR-1307): every stop presses the panel's Cancel and checks the panel
  closed (else the Owner is told to close it with Cancel); for 10 minutes after a stop, every
  3 s, `PasswordsExport.sweep` wipes a file of the export's unique name in the home folder,
  Desktop, Documents, Downloads and iCloud Drive (two levels down) and `Library/CloudStorage`
  (three), and a notification says so.
- A full path in the name field doesn't work: AppKit turns each `/` into `:` and saves in the
  panel's current folder (tried: a file in Downloads).
Only while unlocked, only from a click (menu, Settings, setup, the reminder). Without Accessibility
the hand steps show instead.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/PasswordsExportCleanupTests.swift`
- `macos/Tests/SignInImportTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.

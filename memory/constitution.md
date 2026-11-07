# Constitution

These principles override convenience. A plan that breaks one must say so explicitly and justify it,
or change.

## I. A paired machine never accepts inbound connections
Latchkey on a Mac or a Linux server only dials out. No open ports, no router configuration, no third-party tunnel agent.
NAT traversal is the outbound WebSocket to the relay, nothing else.

## II. Fail fast, never hang
Every request from Claude gets an answer within a bounded time. If a machine is off, asleep, frozen,
or slow, the relay answers with a clear, human-readable reason and the last known state. No code
path may wait on a machine without a deadline.

## III. Disabled means nonexistent
A capability the user has not enabled on a machine is not listed, not callable, and not mentioned
to Claude for that machine. Per-call approval belongs to the Claude apps; capability selection belongs to the user,
on the machine.

## IV. Good citizen
A real Mac app: signed, notarized, sandboxed where possible, using Apple's supported APIs
(SMAppService, XPC, IOKit, Keychain, standard privacy prompts). No Terminal steps, no sudoers edits,
no private frameworks where a public API exists. If the user deletes the app, nothing is left behind.
On Linux: one systemd service, the distribution's own conventions, sudo set up only by the user
(Latchkey never edits sudo's settings), and an uninstall command that leaves nothing behind.

Exception (approved by Toni 2026-11-05): Calendar invitations use EventKit methods Apple doesn't
document, because EventKit has no public way to answer invitations or invite people (spec 007
FR-705 to FR-708, plan D7). Exactly these, the calls Calendar.app itself makes, inside the public
EventKit framework: `EKEvent` `participationStatus`/`setParticipationStatus:`,
`responseComment`/`setResponseComment:`, `addAttendee:`, `removeAttendee:`,
`addOrganizerAndSelfAttendeeForNewInvitation`, the flags `allowsParticipationStatusModifications`,
`allowsAttendeesModifications`, `currentUserMayActAsOrganizer`;
`EKAttendee attendeeWithName:emailAddress:`; `EKSource ownerAddresses`; `EKCalendar`
`selfIdentityEmail`, `ownerIdentityEmail`, `selfIdentityAddress`, `ownerIdentityAddress`. Each is
checked before use, every change is read back, and a test fails when one disappears.

Never disturb the user (approved by Toni 2026-11-07): while the Mac is unlocked, the person at it
may be using any app, so Latchkey never brings a window to the front, never drives an app's
window the user may be using (changing its selection, view, or text), and never sends the
pointer or keystrokes into the user's apps. Work that can't touch what the user sees is fine:
data read or written through an app's scripting or database without its window, a Safari tab of
Claude's own in the background while the user keeps browsing theirs. A feature that would need
the front or another app's window is left out, not built with a guard. Exceptions, because the
user asks for them knowingly: computer control (when Claude uses the computer, the user knows
it), acting in the user's own Safari tabs, and the shell's `open`. Unreliable routes (WhatsApp Web
in Safari) are left out too.

## V. Self-hostable by default
The relay is one Go binary plus one SQLite file, shipped as a Docker image. The hosted instance runs
exactly the same code. No feature may depend on a specific cloud vendor.

## VI. Store the minimum
The relay stores what it needs to authenticate, route, and report status. It does not store tool
results. Anything it does store is listed in `data-model.md`. Secrets are hashed or encrypted at rest.

## VII. Test-first on the contracts
The agent protocol, the MCP surface, and the OAuth flows are specified as contracts. Contract tests
are written and fail before implementation. Integration tests run against a real MCP client, not
mocks of one.

## VIII. Simplicity
A new program, service, or package exists only when a plan names the requirement it serves; no
layers or splits for later. Use framework and SDK features directly instead of wrapping them.
One capability at a time.

## IX. Open source
MIT or Apache-2.0. Dependencies must have compatible licenses (no GPL in the relay or app).

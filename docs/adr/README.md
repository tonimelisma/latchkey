# Architecture decision records

One file per decision, `NNNN-title.md` ([template](0000-template.md)). ADR 0001 is the
constitution, the principles every design is checked against. ADRs 0002 to 0179 are the decisions Dn of each spec's plan, migrated with their text unchanged;
each names its old label ("plan 001 D1") as an alias, which code comments still use. A superseded
or withdrawn ADR stays, with its status saying so. New decisions get the next number.

| ADR | Alias | Decision |
|---|---|---|
| [0001](0001-constitution.md) | memory/constitution.md | Latchkey's constitution (principles I to X) |
| [0002](0002-nat-traversal-the-mac-app-keeps-one-outbound-websocket-to.md) | plan 001 D1 | NAT traversal: the Mac app keeps one outbound WebSocket to the relay |
| [0003](0003-the-relay-is-the-mcp-server-not-a-pass-through.md) | plan 001 D2 | The relay is the MCP server, not a pass-through |
| [0004](0004-deadlines.md) | plan 001 D3 | Deadlines |
| [0005](0005-oauth-authorization-server-zitadel-oidc-plus-claudes-client.md) | plan 001 D4 | OAuth authorization server: zitadel/oidc plus Claude's client registration methods |
| [0006](0006-owner-authentication-passkeys-only-email-recovery.md) | plan 001 D5 | Owner authentication: passkeys only, email recovery |
| [0007](0007-pairing-browser-sign-in-secure-enclave-device-key.md) | plan 001 D6 | Pairing: browser sign-in, Secure Enclave device key |
| [0008](0008-keep-awake-smappservice-helper-daemon.md) | plan 001 D7 | Keep-awake: SMAppService helper daemon |
| [0009](0009-power-and-thermal-monitoring.md) | plan 001 D8 | Power and thermal monitoring |
| [0010](0010-mac-app-packaging.md) | plan 001 D9 | Mac app packaging |
| [0011](0011-relay-implementation.md) | plan 001 D10 | Relay implementation |
| [0012](0012-audit-log-and-local-trace.md) | plan 001 D11 | Audit log and local trace |
| [0013](0013-apps-with-access-one-row-per-approval-pushed-to-the-mac.md) | plan 001 D12 | Apps with access: one row per approval, pushed to the Mac |
| [0014](0014-terms-and-privacy-policy-from-the-operators-settings.md) | plan 001 D13 | Terms and privacy policy, from the operator's settings |
| [0015](0015-operator-commands-in-the-relay-binary-the-running-relay.md) | plan 001 D14 | Operator commands in the relay binary; the running relay follows the database |
| [0016](0016-menu-bar-state-in-the-icons-shape-a-short-menu-a-settings.md) | plan 001 D15 | Menu bar: state in the icon's shape, a short menu, a Settings window, Pause |
| [0017](0017-relay-audit-trail.md) | plan 001 D18 | Relay audit trail |
| [0018](0018-unsettled-states-and-the-installers-checks-of-the-running.md) | plan 001 D17 | Unsettled states, and the installer's checks of the running app |
| [0019](0019-diagnostic-log-in-macoss-unified-log.md) | plan 001 D16 | Diagnostic log in macOS's unified log |
| [0020](0020-mac-audit-trail.md) | plan 001 D19 | Mac audit trail |
| [0021](0021-every-permission-at-first-run.md) | plan 001 D20 | Every permission at first run (FR-623, FR-606) |
| [0022](0022-macoss-monthly-screen-question-while-the-owner-is-here.md) | plan 001 D21 | macOS's monthly screen question while the Owner is here (FR-624) |
| [0023](0023-missing-permissions-named-in-claudes-answer.md) | plan 001 D22 | Missing permissions named in Claude's answer (FR-625) |
| [0024](0024-a-lost-permission-is-told-to-the-owner.md) | plan 001 D23 | A lost permission is told to the Owner (FR-626) |
| [0025](0025-never-stop-reconnecting-one-copy-at-a-time.md) | plan 001 D24 | Never stop reconnecting; one copy at a time (FR-206, FR-207) |
| [0026](0026-add-latchkey-to-claude.md) | plan 001 D25 | Add Latchkey to Claude (FR-627, FR-628, FR-659, FR-660) |
| [0027](0027-no-call-missing-because-the-app-stopped.md) | plan 001 D27 | No call missing because the app stopped (FR-666 to FR-668) |
| [0028](0028-latchkeys-log-for-claude.md) | plan 001 D26 | Latchkey's log for Claude (FR-662 to FR-665) |
| [0029](0029-full-traces-in-daily-files.md) | plan 001 D28 | Full traces in daily files (FR-680 to FR-689; spec 010 FR-1057 to FR-1059) |
| [0030](0030-the-hosted-relays-server-locked-down-and-watched.md) | plan 001 D29 | The hosted relay's server: locked down and watched (2026-11-21) |
| [0031](0031-tools-claude-sees.md) | plan 002 D1 | Tools Claude sees |
| [0032](0032-reading-the-databases-read-only.md) | plan 002 D2 | Reading: the databases, read-only |
| [0033](0033-changing-through-the-apps-with-apple-events.md) | plan 002 D3 | Changing: through the apps, with Apple Events |
| [0034](0034-changing-in-notes-window.md) | plan 002 D3a | Changing in Notes' window (2026-11-04) |
| [0035](0035-changing-in-messages-window.md) | plan 002 D3b | Changing in Messages' window (2026-11-05) |
| [0036](0036-people-contacts.md) | plan 002 D4 | People: Contacts |
| [0037](0037-permissions-and-setup.md) | plan 002 D5 | Permissions and setup |
| [0038](0038-text-written-by-others.md) | plan 002 D6 | Text written by others |
| [0039](0039-mac-state-in-every-answer.md) | plan 002 D7 | Mac state in every answer (spec 001 FR-065) |
| [0040](0040-visibility-on-the-mac.md) | plan 002 D8 | Visibility on the Mac |
| [0041](0041-capability-levels-in-the-app-and-protocol.md) | plan 002 D9 | Capability levels in the app and protocol |
| [0042](0042-tools.md) | plan 003 D1 | Tools |
| [0043](0043-reading.md) | plan 003 D2 | Reading |
| [0044](0044-changing.md) | plan 003 D3 | Changing |
| [0045](0045-search.md) | plan 003 D4 | Search |
| [0046](0046-levels-and-setup.md) | plan 003 D5 | Levels and setup |
| [0047](0047-tools.md) | plan 004 D1 | Tools (level On) |
| [0048](0048-running.md) | plan 004 D2 | Running |
| [0049](0049-jobs.md) | plan 004 D3 | Jobs |
| [0050](0050-output.md) | plan 004 D4 | Output |
| [0051](0051-levels-and-visibility.md) | plan 004 D5 | Levels and visibility |
| [0052](0052-leftovers-are-followed-and-swept.md) | plan 004 D6 | Leftovers are followed and swept (FR-313, FR-324, FR-326) |
| [0053](0053-leases.md) | plan 004 D7 | Leases (FR-314) |
| [0054](0054-scratch-folder.md) | plan 004 D8 | Scratch folder (FR-315, FR-316) |
| [0055](0055-the-fence.md) | plan 004 D9 | The fence (FR-317 to FR-320) |
| [0056](0056-what-a-job-left.md) | plan 004 D10 | What a job left (FR-321, FR-323) |
| [0057](0057-changes-that-got-past-the-fence.md) | plan 004 D11 | Changes that got past the fence (FR-325) |
| [0058](0058-jobs-in-every-answer.md) | plan 004 D12 | Jobs in every answer (FR-322) |
| [0059](0059-self-check-at-start.md) | plan 004 D13 | Self-check at start (FR-330, 2026-10-29) |
| [0060](0060-tools.md) | plan 005 D1 | Tools |
| [0061](0061-safari-through-apple-events.md) | plan 005 D2 | Safari through Apple Events |
| [0062](0062-reading-and-acting.md) | plan 005 D3 | Reading and acting |
| [0063](0063-setup-and-errors.md) | plan 005 D4 | Setup and errors |
| [0064](0064-levels.md) | plan 005 D5 | Levels |
| [0065](0065-claudes-page-as-a-tab-in-the-owners-window.md) | plan 005 D6 | Claude's page as a tab in the Owner's window (2026-10-29) |
| [0066](0066-while-the-mac-is-locked-a-browser-of-latchkeys-own.md) | plan 005 D7 | While the Mac is locked: a browser of Latchkey's own (FR-420 to FR-422, decided 2026-11-02) |
| [0067](0067-the-owners-tabs-and-windows.md) | plan 005 D8 | The Owner's tabs and windows (decided 2026-11-03) |
| [0068](0068-a-pages-own-dialogs.md) | plan 005 D9 | A page's own dialogs (FR-432, decided 2026-11-03) |
| [0069](0069-keys-hover-scrolling-lists-files-and-pictures-without-the.md) | plan 005 D10 | Keys, hover, scrolling, lists, files, and pictures without the screen (2026-11-05) |
| [0070](0070-claudes-pages-in-latchkeys-own-browser-by-name-with-dialogs.md) | plan 005 D11 | Claude's pages in Latchkey's own browser, by name, with dialogs Claude answers (2026-11-15) |
| [0071](0071-sign-in-cookies-in-latchkeys-log.md) | plan 005 D12 | Sign-in cookies in Latchkey's log (FR-453, FR-454, 2026-11-15) |
| [0072](0072-signed-in-sites-in-safari-while-unlocked.md) | plan 005 D13 | Signed-in sites in Safari while unlocked (FR-455 to FR-459, 2026-11-15) |
| [0073](0073-the-background-browser-by-default-safari-to-watch-and-pages.md) | plan 005 D14 | The background browser by default, Safari to watch, and pages' own saves (FR-474 to FR-477, 2026-11-24) |
| [0074](0074-real-mouse-and-keyboard-in-latchkeys-own-browser.md) | plan 005 D15 | Real mouse and keyboard in Latchkey's own browser (FR-478 to FR-489, 2026-11-25) |
| [0075](0075-tools.md) | plan 006 D1 | Tools |
| [0076](0076-screen-state.md) | plan 006 D2 | Screen state (FR-504, FR-505) |
| [0077](0077-seeing.md) | plan 006 D3 | Seeing |
| [0078](0078-acting.md) | plan 006 D4 | Acting |
| [0079](0079-permissions-and-setup.md) | plan 006 D5 | Permissions and setup (FR-506) |
| [0080](0080-visibility.md) | plan 006 D6 | Visibility (FR-507) |
| [0081](0081-safari-window-screenshot.md) | plan 006 D7 | Safari window screenshot (FR-509) |
| [0082](0082-forms-in-a-named-app.md) | plan 006 D8 | Forms in a named app (FR-511 to FR-514, 2026-11-03) |
| [0083](0083-tools-claude-sees.md) | plan 007 D1 | Tools Claude sees |
| [0084](0084-calendar-and-reminders-eventkit.md) | plan 007 D2 | Calendar and Reminders: EventKit (FR-701 to FR-712, FR-744) |
| [0085](0085-reminders-flags-tags-subtasks-and-sections.md) | plan 007 D7 | Reminders' flags, tags, subtasks, and sections (FR-714 to FR-719) |
| [0086](0086-contacts.md) | plan 007 D3 | Contacts (FR-721, FR-722, FR-745) |
| [0087](0087-location-and-maps.md) | plan 007 D4 | Location and Maps (FR-731 to FR-734) |
| [0088](0088-capabilities-levels-permissions-setup.md) | plan 007 D5 | Capabilities, levels, permissions, setup (FR-741, FR-742) |
| [0089](0089-visibility.md) | plan 007 D6 | Visibility (FR-743, FR-746) |
| [0090](0090-invitations-answers-invitees-others-events.md) | plan 007 D7 | Invitations: answers, invitees, others' events (FR-705 to FR-708; 2026-11-05) |
| [0091](0091-tools-claude-sees.md) | plan 008 D1 | Tools Claude sees |
| [0092](0092-reading-the-envelope-index-and-the-message-files.md) | plan 008 D2 | Reading: the Envelope Index and the message files (FR-801, FR-803, FR-807, FR-831, FR-834) |
| [0093](0093-find-filters.md) | plan 008 D3 | Find filters (FR-801, SC-801) |
| [0094](0094-text-search.md) | plan 008 D4 | Text search (FR-802) |
| [0095](0095-reading-a-message-and-its-attachments.md) | plan 008 D5 | Reading a message and its attachments (FR-803 to FR-805, FR-807) |
| [0096](0096-changes-through-mails-scripting-writing-in-mails-window.md) | plan 008 D6 | Changes through Mail's scripting, writing in Mail's window (FR-810, FR-811, FR-820 to FR-823) |
| [0097](0097-writing-by-scripting-the-text-in-a-signature-for-a-moment.md) | plan 008 D6a | Writing by scripting, the text in a signature for a moment (FR-841 to FR-845, 2026-11-05) |
| [0098](0098-sending-confirmed-in-sent.md) | plan 008 D7 | Sending confirmed in Sent (FR-823, FR-824) |
| [0099](0099-level-setup-permissions-activity.md) | plan 008 D8 | Level, setup, permissions, activity (FR-830, FR-832, FR-833) |
| [0100](0100-text-by-others.md) | plan 008 D9 | Text by others (FR-806) |
| [0101](0101-queued-email-while-the-mac-is-locked.md) | plan 008 D10 | Queued email while the Mac is locked (FR-835 to FR-837, decided 2026-11-02) |
| [0102](0102-mail-held-by-an-alert.md) | plan 008 D11 | Mail held by an alert (FR-839) |
| [0103](0103-sign-up-with-a-setup-code-no-email-server.md) | plan 009 D1 | Sign-up with a setup code, no email server (FR-907, FR-908) |
| [0104](0104-recovery-code-from-the-operator.md) | plan 009 D2 | Recovery code from the operator (FR-914) |
| [0105](0105-readiness-for-update-rollback.md) | plan 009 D3 | Readiness for update rollback (FR-909) |
| [0106](0106-a-copy-of-the-database-before-a-schema-change.md) | plan 009 D4 | A copy of the database before a schema change (FR-909) |
| [0107](0107-session-cookie-bound-to-the-host.md) | plan 009 D5 | Session cookie bound to the host (FR-912) |
| [0108](0108-public-images-with-every-deploy.md) | plan 009 D6 | Public images with every deploy (FR-911) |
| [0109](0109-the-guide.md) | plan 009 D7 | The guide (FR-901, FR-902, FR-904, FR-905, FR-906, FR-910) |
| [0110](0110-testing-the-guide.md) | plan 009 D8 | Testing the guide (SC-902, SC-903) |
| [0111](0111-set-one-up-with-claude-in-the-mac-app.md) | plan 009 D9 | "Set one up with Claude" in the Mac app (FR-903) |
| [0112](0112-several-devices-per-account.md) | plan 010 D1 | Several devices per account (FR-1001, FR-1002, FR-1011, FR-1012) |
| [0113](0113-tool-list-union-with-per-kind-notes.md) | plan 010 D2 | Tool list: union with per-kind notes (FR-1003, FR-1004, FR-1007; decided 2026-10-31) |
| [0114](0114-protocol-additions.md) | plan 010 D3 | Protocol additions (FR-1002, FR-1009, FR-1020) |
| [0115](0115-choosing-the-machine-for-a-call.md) | plan 010 D4 | Choosing the machine for a call (FR-1005, FR-1007, FR-1008) |
| [0116](0116-status-line-and-offline-answers.md) | plan 010 D5 | Status line and offline answers (FR-1008, FR-1009; decided 2026-10-31: list the others) |
| [0117](0117-the-machines-tool-and-instructions.md) | plan 010 D6 | The machines tool and instructions (FR-1006) |
| [0118](0118-headless-pairing.md) | plan 010 D7 | Headless pairing (FR-1022; RFC 8628's shape) |
| [0119](0119-the-linux-program.md) | plan 010 D8 | The Linux program (FR-1020 to FR-1027; contracts/server-program.md) |
| [0120](0120-shell-on-linux.md) | plan 010 D9 | Shell on Linux (FR-1030 to FR-1034) |
| [0121](0121-files-on-linux.md) | plan 010 D10 | Files on Linux (FR-1040 to FR-1044) |
| [0122](0122-activity-on-linux.md) | plan 010 D11 | Activity on Linux (FR-1050, FR-1051) |
| [0123](0123-install-updates-uninstall.md) | plan 010 D12 | Install, updates, uninstall (FR-1026, FR-1027) |
| [0124](0124-mac-app.md) | plan 010 D13 | Mac app (FR-1002, FR-1012) |
| [0125](0125-testing.md) | plan 010 D14 | Testing (Constitution VII; decided 2026-10-31: container on this Mac and the Google VM) |
| [0126](0126-latchkeys-log-for-claude-on-linux.md) | plan 010 D15 | Latchkey's log for Claude on Linux (FR-1052 to FR-1056; decided 2026-11-03) |
| [0127](0127-full-traces-in-daily-files.md) | plan 010 D16 | Full traces in daily files (FR-1057 to FR-1059; decided 2026-11-15) |
| [0128](0128-a-plugin-of-skills-only.md) | plan 011 D1 | A plugin of skills only (FR-1101, FR-1102, FR-1106) |
| [0129](0129-where-it-lives.md) | plan 011 D2 | Where it lives (FR-1110) |
| [0130](0130-the-two-skills.md) | plan 011 D3 | The two skills (FR-1103, FR-1104, FR-1106, FR-1107) |
| [0131](0131-the-relay-guide-moves-into-the-plugin.md) | plan 011 D4 | The relay guide moves into the plugin (FR-1105, FR-1113) |
| [0132](0132-versions.md) | plan 011 D5 | Versions (FR-1111) |
| [0133](0133-telling-the-owner.md) | plan 011 D6 | Telling the Owner (FR-1112) |
| [0134](0134-content-checks.md) | plan 011 D7 | Content checks (FR-1120; Constitution VII, tests first) |
| [0135](0135-measuring-with-real-claude.md) | plan 011 D8 | Measuring with real Claude (FR-1121) |
| [0136](0136-shipping.md) | plan 011 D9 | Shipping (CLAUDE.md "Every increment ships") |
| [0137](0137-the-owners-whatsapp-web-tab-in-safari.md) | plan 012 D1 | The Owner's WhatsApp Web tab in Safari |
| [0138](0138-driving-whatsapp-web-its-own-functions-not-its-screen.md) | plan 012 D2 | Driving WhatsApp Web: its own functions, not its screen |
| [0139](0139-whatsapp-for-macs-window.md) | plan 012 D3 | WhatsApp for Mac's window (withdrawn 2026-11-04) |
| [0140](0140-whatsapp-for-macs-window-again-as-the-fallback.md) | plan 012 D3b | WhatsApp for Mac's window again, as the fallback (2026-11-05) |
| [0141](0141-latchkeys-own-device-removed.md) | plan 012 D4 | Latchkey's own device, removed |
| [0142](0142-tools.md) | plan 012 D5 | Tools |
| [0143](0143-deadline.md) | plan 012 D6 | Deadline |
| [0144](0144-off.md) | plan 012 D7 | Off |
| [0145](0145-where-the-copies-live.md) | plan 013 D1 | Where the copies live (FR-1310, FR-1305) |
| [0146](0146-taking-a-file-in.md) | plan 013 D2 | Taking a file in (FR-1300, FR-1301, FR-1303) |
| [0147](0147-the-one-touch-export.md) | plan 013 D3 | The one-touch export (FR-1301, FR-1306) |
| [0148](0148-the-weekly-reminder.md) | plan 013 D4 | The weekly reminder (FR-1304) |
| [0149](0149-the-tools.md) | plan 013 D5 | The tools (FR-1320, FR-1326, FR-1340, FR-1371; contract `contracts/login-tools.md`) |
| [0150](0150-typing-into-a-page.md) | plan 013 D6 | Typing into a page (FR-1321, FR-1328, FR-1371, FR-1372, FR-1311) |
| [0151](0151-retries-and-the-log.md) | plan 013 D7 | Retries and the log (FR-1324 withdrawn, FR-1327) |
| [0152](0152-where-the-owner-sees-it.md) | plan 013 D8 | Where the Owner sees it (FR-1301, FR-1302, FR-1305) |
| [0153](0153-latchkeys-own-sign-ins.md) | plan 013 D10 | Latchkey's own sign-ins (FR-1350, FR-1351, FR-1353 to FR-1355, FR-1374) |
| [0154](0154-codes-texted-to-the-owner.md) | plan 013 D11 | Codes texted to the Owner (FR-1360, FR-1362, FR-1363) |
| [0155](0155-codes-emailed-to-the-owner.md) | plan 013 D12 | Codes emailed to the Owner (FR-1364 to FR-1367) |
| [0156](0156-tests-and-checks.md) | plan 013 D9 | Tests and checks |
| [0157](0157-the-setting.md) | plan 014 D1 | The setting (FR-1400 to FR-1403) |
| [0158](0158-asking-claude.md) | plan 014 D2 | Asking Claude (FR-1401, FR-1405, FR-1406) |
| [0159](0159-filing-on-the-relay.md) | plan 014 D3 | Filing on the relay (FR-1410 to FR-1416) |
| [0160](0160-the-intake.md) | plan 014 D4 | The intake (FR-1420 to FR-1425) |
| [0161](0161-name-and-hosting.md) | plan 014 D4a | Name and hosting (FR-1426) |
| [0162](0162-the-developers-agent.md) | plan 014 D5 | The developer's agent (FR-1430, FR-1431) |
| [0163](0163-tests.md) | plan 014 D6 | Tests |
| [0164](0164-everything-for-that-chat.md) | plan 014 D7 | Everything for that chat (FR-1440 to FR-1456; 2026-11-25) |
| [0165](0165-one-program-relay-cmd-e2e.md) | plan 015 D1 | One program, `relay/cmd/e2e` (FR-1500 to FR-1506, FR-1515 to FR-1526) |
| [0166](0166-picking-what-runs.md) | plan 015 D2 | Picking what runs (FR-1500, FR-1502, FR-1504) |
| [0167](0167-the-per-pull-request-workflow.md) | plan 015 D3 | The per-pull-request workflow (FR-1501 to FR-1506) |
| [0168](0168-tool-snapshots.md) | plan 015 D4 | Tool snapshots (FR-1504) |
| [0169](0169-the-weekly-run.md) | plan 015 D5 | The weekly run (FR-1510 to FR-1517) |
| [0170](0170-the-prepared-image.md) | plan 015 D6 | The prepared image (FR-1512, FR-1513) |
| [0171](0171-results-and-the-reminder.md) | plan 015 D7 | Results and the reminder (FR-1511, FR-1530 to FR-1533) |
| [0172](0172-tasks.md) | plan 015 D8 | Tasks (FR-1520 to FR-1526) |
| [0173](0173-releases-and-the-requesters-conditions.md) | plan 015 D9 | Releases and the requester's conditions (FR-1540, FR-1541) |
| [0174](0174-fast-layer-gates-on-fake-clocks.md) | plan 016 D1 | Fast layer gates, on fake clocks (FR-1601, FR-1602) |
| [0175](0175-one-end-to-end-harness.md) | plan 016 D2 | One end-to-end harness (FR-1603, FR-1604) |
| [0176](0176-the-sandbox-mac.md) | plan 016 D3 | The sandbox Mac (FR-1605, FR-1606, FR-1607, FR-1610) |
| [0177](0177-evals-in-the-same-sandbox.md) | plan 016 D4 | Evals in the same sandbox (FR-1608) |
| [0178](0178-retire-the-hand-run-kits.md) | plan 016 D5 | Retire the hand-run kits (FR-1609) |
| [0179](0179-two-ways-to-work.md) | plan 016 D6 | Two ways to work (spec: the maintainer's choices) |
| [0180](0180-releases-run-after-ci-passes-on-main.md) | (new) | Releases run after CI passes on main |

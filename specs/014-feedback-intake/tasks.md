# Spec 014 tasks: problem reports to the developer

Built 2026-11-23 (Toni: "finish all the work without stopping"), test-first where a test could
run here; the Mac app's tests run on GitHub's macOS runner (`mac-build.yml`).

- [x] T1 The report format: fields, HPKE sealing to the developer's key, the proof of work
  (`relay/reports`, tests) — FR-1412, FR-1413, FR-1420
- [x] T2 The developer's key pair made; its public half built in (`relay/reports/developer.pub`),
  the private half handed to Toni, never in the repository — FR-1430
- [x] T3 [P] Relay storage: `report_outbox` replaces `feedback` (migration 00015), the reporter
  tag (`store/reports.go`, tests); data model and privacy policy updated — FR-1403, FR-1412,
  FR-1414
- [x] T4 Relay: the `feedback` tool only while a machine shares and nothing blocks; the error
  line; sealing and queueing; the sender with backoff, the 7-day limit, and the check before each
  send; settings `REPORTS_INTAKE_URL`, `REPORTS_DEVELOPER_KEY`, `REPORTS_BLOCK`; the block in the
  welcome; delivery to the Mac removed (tests with a real MCP client and a stand-in intake) —
  FR-1401 to FR-1416, FR-1415a
- [x] T5 [P] The intake: take, list, get, delete; size, proof of work, per-sender limit, a bound
  on waiting reports, the developer's token (`relay/internal/intake`, tests); its program,
  image, and signed publishing — FR-1420 to FR-1425
- [x] T6 [P] The developer's command `latchkey-reports` (keygen, list, delete) — FR-1423, FR-1430
- [x] T7 Mac app: the setting, explained before it takes effect; `share_reports` in the state; the
  relay's block shown; the Feedback folder and the `feedback` feature removed — FR-1400 to
  FR-1403, FR-1415a
- [x] T8 Docs: README, CLAUDE.md's session start, docs/cloud-sessions.md, STATUS, decisions,
  spec 001's withdrawn requirements, the agent protocol contract; regression cases
- [toni] T9 Toni: the private key into his personal cloud environment (`LATCHKEY_REPORTS_KEY`).
  Done 2026-11-24: the intake deployed by the hosted server's own agent, and its token saved as a
  network secret for the intake's host (the intake answers `[]` from a cloud session). That
  secret was gone by 2026-11-26 (in none of Toni's cloud environments); Toni saved it again on
  the `latchkey` environment that day, which also allows the host, and `latchkey-reports list`
  answered from a cloud session. The token's source is the intake's own `DEVELOPER_TOKEN`.

## Everything for that chat (2026-11-25; FR-1440 to FR-1456)

- [x] T10 Relay: the trace line's session; the chat's calls (session, earlier sessions that used
  its pages, a client's last 2 hours); the relay's log ring; asking the machines for their parts
  with a 10 s deadline; blanking codes and secrets by place, labels for names; 5 MB with oldest
  first left out; the small version for an older intake (tests with a real MCP client) —
  FR-1440 to FR-1451
- [x] T11 [P] Intake: 5 MB; bytes per sender per hour; bytes waiting in all — FR-1455, FR-1456
- [x] T12 [P] `latchkey-reports`: summaries in list; `show` writes files — FR-1452
- [x] T13 [P] Linux server: its part (log, calls), not while paused — FR-1444
- [x] T14 Mac: the page record in a hidden world; page descriptions (own browser and Claude's
  Safari tabs); the part; the feature in hello; the setting's words; tests on GitHub's runner —
  FR-1444 to FR-1447, FR-1454
- [x] T15 The feedback tool's description; README, STATUS, decisions, contracts — FR-1453
- [toni] T16 Toni: a live report from his Mac (any chat that hits a problem, with sharing on)

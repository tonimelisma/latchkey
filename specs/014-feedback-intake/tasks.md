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
- [toni] T9 Toni: the private key into his personal cloud environment (`LATCHKEY_REPORTS_KEY`);
  done 2026-11-24: pilvi's agent deployed the intake (tonimelisma/pilvi#15, #16; signed image
  `804e0500…`, its own network with Caddy), and the intake's token is a network secret for its
  host (the intake answers `[]` from a cloud session)

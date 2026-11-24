# Contract: a weekly result in the developer's intake (FR-1530 to FR-1533)

Sent from inside the test Mac copy to the intake's existing report endpoint (spec 014
FR-1420), sealed to the developer's key exactly as a problem report is; the intake can't tell
the two apart. Each sealed entry is at most 64 KB; a larger result is split into parts
(research.md decision 3).

Sealed payload (JSON, gzip before sealing):

```json
{
  "kind": "eval",
  "format": 1,
  "run": "ev_7f3c…",
  "part": 1, "parts": 2,
  "started": "2026-11-29T21:05:00Z", "finished": "2026-11-29T21:52:00Z",
  "latchkey": "mac-0.8.240", "macos": "26.1 (VM)", "claude_code": "2.x", "model": "sonnet",
  "setup_ok": true,
  "checks": [{"capability": "files", "name": "files_read on a picture", "result": "passed"}],
  "tasks": [{
    "id": "notes.append-to-shopping-list", "held_out": false,
    "tries": [{"passed": true, "calls": ["notes_find", "notes_change"], "forbidden": [],
               "unneeded": [], "tool_errors": 0, "turns": 4, "tokens_in": 9100,
               "tokens_out": 410, "seconds": 38}],
    "passes": 3, "of": 3
  }],
  "not_run": ["browser.download-statement"],
  "rows_unreachable": ["locked", "lid closed", "real iMessage", "real sites"]
}
```

- A failed try also holds its tool calls with arguments and answers, cut to fit; never any
  data of Toni's (the copy holds none).
- `setup_ok: false` with `missing_permissions` when the image lost a permission (FR-1513); then
  `tasks` is empty.
- The developer's command lists entries by kind: `latchkey-reports list` shows problem reports;
  `latchkey-reports evals` shows weekly results, joined by `run`, with the previous week's
  comparison (FR-1531); `latchkey-reports delete <id>` removes each part (FR-1533).

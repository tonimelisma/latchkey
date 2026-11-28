# Lessons

Bounded: rules learned the hard way that are not obvious from the code, and problems still open.
When an open problem is solved, or a rule moves into a test, an ADR or CLAUDE.md, its entry is
deleted here. Path-specific rules learned on the Mac app and the relay live in `.claude/rules/`.

## Rules learned

- A scripted edit must assert that the old text is there: after a formatter rewrapped a line, a
  silent replace shipped two releases without Browser and Computer control registered (guarded
  now by `everyCapabilityIsRegistered`; `.claude/rules/macos.md`).
- Never pause, disconnect or turn down capabilities on an installed app for a check: its user's
  own Claude sessions use it. Test those in unit tests, `e2e mac` or the sandbox Mac.
- A tool that guesses what a page or app state means fails in ways no test foresaw: a sign-in
  tool that judged page states caused most of a weekend's failures, which is why a tool reports
  and Claude judges (ADR 0001, X).
- Anything decided at an app's start must not read state that only arrives a moment later: the
  setup window opened on every start while "is this Mac paired?" was read from a connection
  that hadn't reported yet.
- The Mac runner's timing differs from a real Mac's (a 2.8 s limit measured 13.6 s beside other
  test programs): tests that measure time limits run alone (`macos/scripts/shard-suites.py`).

## Open problems

- 312 requirements have no tagged test yet ([#75](https://github.com/tonimelisma/latchkey/issues/75)).
- Open items from the spec task lists, mostly live checks
  ([#76](https://github.com/tonimelisma/latchkey/issues/76)).

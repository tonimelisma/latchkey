# Spec 011 tasks

Written with the plan and built in one go (Toni, 2026-11-01). ✅ done.

- **T1101** ✅ Content checks `plugin/tests/check.sh` (C1 to C7) with their own tests
  `plugin/tests/contract_test.sh` (the real plugin passes; 14 planted faults each fail with
  their item), and `plugin/Makefile` (`test`, `lint`, `measure`); seen failing (13 of 15) with
  no plugin.
- **T1102** ✅ [P] Manifest and catalog (C2, C3); README of the plugin.
- **T1103** ✅ [P] Skill `latchkey` (D3).
- **T1104** ✅ [P] Skill `set-up-latchkey` (D3); the relay guide moved in as `own-relay.md` (D4),
  with links in README, docs/self-hosting.md, spec 009, `deploy/lib.sh`, and
  `relay/cmd/guidecheck` updated.
- **T1105** ✅ Eval cases and pretend Latchkey tools (D8).
- **T1106** ✅ [P] Mac app: Copy Request at the guide's new address; its test; version 0.8.62.
- **T1107** ✅ [P] Relay account page: the plugin line under Claude (D6), with its test; README
  Get started step.
- **T1108** ✅ Measure (D8). Sonnet, judge Haiku, 3 runs per arm, 2026-11-01:

  | Case | With | Without | Δ |
  |---|---|---|---|
  | no-tools | 1.00 | 0.00 | +1.00 |
  | pair-server | 1.00 | 0.00 | +1.00 |
  | offline-mac | 1.00 | 1.00 | 0 |
  | two-machines | 1.00 | 1.00 | 0 |
  | refusal | 1.00 | 1.00 | 0 |
  | unrelated (no skill loads) | 1.00 | 1.00 | 0 |

  About $1.30 per full run. Found and fixed on the way: the first wording of "don't get around a
  refusal" made Claude refuse Latchkey's shell because its own local shell was off (the skill
  now says where things run and that the rule is about Latchkey's refusals only); with no tools
  Claude offered help instead of giving the steps (the steps are now in the skill); once the
  skill didn't load for "my Mac's battery" (its description now names such requests). The tool
  descriptions already make Sonnet handle offline machines, two machines, and refusals well:
  the skill doesn't change those, and doesn't make them worse.
- **T1109** ✅ Ship (D9), 2026-11-01: plugin, relay (tests, lint, ShellCheck) and Mac app checks;
  the Mac suite's only failures are the page-script, shell-job, and leftovers tests already
  failing on unchanged main on this Mac (docs/STATUS.md), plus the large-log test, which passes
  alone (9.8 s) and timed out only under the full parallel run. Main at 03639ff; relay deployed;
  app 0.8.62 installed (paired, keep-awake on, helper running, all calls match the audit). Live,
  from a fresh clone of GitHub's main: the guide's raw address answers, the validator passes, and
  a fresh Claude Code session outside the repository with the plugin and the hosted connector
  listed both of Toni's machines with `machines`, gave the server pairing steps from
  set-up-latchkey, and answered "is my Mac awake" from `machines`. Adding the catalog on Toni's
  claude.ai account is his step (his account settings).

# Spec 016: Test strategy and two ways to work — research

Gathered 2026-11-26 in a cloud session at Toni's request ("you don't really have a proper test
strategy here ... research best practices"; "streamline as much as possible. speed is
essential, but it needs to be ecologically valid"; "do a proper audit of CLAUDE.md anyway").
What and why: `spec.md`.

## 1. What exists today (inventory, 2026-11-26)

GL = GitHub Linux runner, GM = GitHub macOS 26 runner, VM = cloud session, TM = Toni's Mac.

| Kind | What is real | Where, when | Size | Run today? |
|---|---|---|---|---|
| relay `make test` | unit and contract tests; headless Chrome sign-up, OAuth, pairing with a real MCP client and the pretend Mac (`internal/testagent`); shared protocol fixtures (`specs/001-core/contracts/fixtures`) | VM, GL (`ci.yml`, again in `relay-image.yml`) | 427 tests | yes, gating |
| relay `make lint`, `make security`, `make script-tests` | linters, vulnerability and secret scans, the repository scripts with stand-in gh | VM (security needs extra hosts), GL | 15 script tests | yes, gating |
| linux `make test` | Go unit tests | VM, GL | 59 tests | yes, gating |
| linux `make test-linux` | every test on Debian with systemd in Docker | by hand | — | no workflow runs it |
| `linuxcheck` (`make check`) | private relay, pretend Mac, the real Linux program installed in a container, real MCP client, snapshots | GL `e2e.yml` | — | yes, reported |
| `e2e relay` | the relay's own tools through a private relay, snapshots | GL `e2e.yml` | — | yes, reported |
| `e2e mac` + `E2EHostTests` | the app's real tool code, in-process in the Debug test host, through a real MCP client and private relay; files, shell, own browser (served pages), a capability off, offline; 32 snapshots | GM `e2e.yml` | 4 checks | yes, reported; Notes, Calendar, Reminders, Contacts, Messages, Mail, WhatsApp, Computer, Logins, Location skipped |
| macos `make test` (`mac-build.yml`, 4 jobs) | Swift Testing, hosted in the app; stand-ins for Safari, Mail, Messages, the lock; real WebKit on local pages | GM per PR, ~4.5 min | ≈959 tests | lint and build gate; the tests are reported only, ~30 timing tests fail on main |
| Regression tests | one per `cases.json` regression row | Go in `ci.yml`; Swift on GM, reported | 119 rows | the Swift half does not gate |
| `claude-check` (`localcheck`), `guidecheck` | real Claude Code, private relay, pretend Mac | by hand | — | not run (no live checks since 2026-11-23) |
| `mac-check` (`maccheck` + `LiveRelayTests`) | the app's connection code, private relay | TM by hand | 1 test | last 2026-10-20 |
| `safari-check.sh` | real Safari, local pages | TM by hand, unlocked | — | passed once |
| `state-check/` | real Claude, hosted relay, Toni's real Mac, apps and data, each screen state | TM | 237 cases | not run since 2026-11-23 |
| `weekly-eval.sh` + `eval-image.sh` | installed release in a Tart VM, real permissions, real Claude (Sonnet), 20 tasks × 3 | Tart, by hand | ≤1 h | never run |
| install checks (`install-lib.sh`) | pairing kept after an install | TM updater, each tag | — | yes |

What this shows:

1. Files, shell and the own browser are checked three or four times; Notes, Calendar,
   Reminders, Contacts, Messages, Mail, Logins and Computer only against stand-ins.
2. Nothing that runs today uses real permissions, a built `.app`'s start and update path, or a
   screen state: the only routes there (`state-check`, Tart) are not run.
3. The Mac suite, with every Swift regression test, does not gate merging.
4. The same setup (private relay, Chrome sign-up, OAuth, pairing) is built in seven harnesses
   (`TestEndToEndInBrowser`, `e2e relay`, `e2e mac`, `linuxcheck`, `localcheck`, `maccheck`,
   `guidecheck`); "a capability turned off disappears" is checked in five; the tool list is
   pinned three times (`PublicToolsTests`, sentence-pinning regression tests, toolsnaps).
5. `ci.yml` runs on both push and pull request (each push to a PR runs twice); the release
   workflows run the same tests again after merge.
6. Every check with real Claude depends on someone running it by hand.

## 2. What good practice says (sources at the end)

- **Shape.** For systems whose bugs live at the seams between services, the "honeycomb"
  (Spotify) puts most weight on integration tests at each boundary, with few unit and few
  end-to-end tests; the pyramid (Fowler, Google's "Just say no to more end-to-end tests") and
  the trophy (Dodds) agree that end-to-end tests are few, slow and flaky. Latchkey's seams are
  the MCP surface, the relay–Mac protocol, and macOS's APIs.
- **Sizes and hermeticity** (Google): small (one process, no network or sleep), medium (one
  machine, localhost), large. Flakiness grows with size (0.5 %, 1.6 %, 14 %).
- **Fakes are checked against reality** (Software Engineering at Google, ch. 13): every stand-in
  in the fast layers needs a layer that runs the real thing, or the stand-in drifts. Latchkey has
  the stand-ins but almost no real-adapter layer.
- **Contracts:** shared golden messages checked by both sides (Latchkey already has
  `specs/001-core/contracts/fixtures`); snapshots of the tool list.
- **Time:** never assert on wall-clock time on shared runners; use fake clocks (Go's
  `testing/synctest`, an injected clock in Swift). This is the root of the ~30 failing timing
  tests on GM.
- **Speed budgets:** the commit stage under 5 minutes, never over 10 (Humble & Farley; Beck's
  ten-minute build); select tests by changed paths; shard only slow layers; flaky tests fixed or
  quarantined with an owner and a date, never left red.
- **Same command locally and in CI.**
- **Mac permissions (TCC)** can't be granted interactively on CI; practitioners pre-grant in a
  throwaway VM (Tart, Anka) or insert rows into the user's permission database there; screen
  recording can't be granted by a profile. A separate test bundle ID keeps grants and data apart
  from the installed app.
- **Evals** (Anthropic, "Writing effective tools for agents", "Demystifying evals for AI
  agents"): realistic multi-step tasks with checkable end states, clean environment per trial,
  held-out tasks, pass^k for regression sets, run on tool or description changes and on model
  upgrades, reported as rates rather than a merge gate. Prompt injection measured as in AgentDojo.
- **After release:** a scripted probe (synthetic monitoring) against the released system with
  test machines and data, never as a replacement for earlier layers.
- **Device-only states** (locked, lid closed): logic tested with an injected state source; the
  real state only on the device, by the owner's checklist or by evidence recorded during real use.

## 3. A sandboxed copy of Latchkey (Toni: "instead of installing, maybe a sandboxed copy")

Verified in code: a Debug build is already a different app to macOS: "Latchkey Dev",
`net.melisma.latchkey.dev` (`macos/project.yml:39-55`, `Shared/AppIdentity.swift:33-46`), with
its own settings, Keychain service, permissions, helper label, Application Support folder,
link scheme; Sparkle off (`Updates.swift:29-31`); `SingleCopy` is per bundle ID, so it runs next
to the installed app; it pairs with a relay on `http://localhost` (`Pairing.swift:134-146`).
`make run` builds and opens it.

Not separated: the home folder. A dev copy in Toni's account sees his real Messages, Notes,
Contacts, Calendar, Safari and files (`Permissions.swift:9-11`, `MessagesCapability.swift:137`).
Hazards found:

- **Install hazard (bug):** both builds are named `Latchkey.app`. `AppLocation.needsMove`
  (`App/Installation.swift:9`) only spares Xcode's build folders, so a dev copy started from
  anywhere else offers to move itself, and accepting removes `/Applications/Latchkey.app`.
- **Keep-awake:** each helper sets the Mac-wide `pmset disablesleep` (`Helper/main.swift:93-112`),
  so two helpers fight.
- Debug builds carry the debugging entitlement (`project.yml:32-35`): another program running as
  Toni could attach to a dev copy that holds Full Disk Access or Accessibility.

Permissions are kept per bundle ID and designated requirement: any stable signing certificate
keeps the grants across rebuilds (a self-signed one made for the sandbox does, which is the
common way to keep Accessibility grants for self-built tools); ad-hoc signing
(`CODE_SIGN_IDENTITY=-`, used by `e2e mac`) loses them on every build (macOS knowledge, not
verified on Latchkey). The sandbox uses its own self-signed identity, never the owner's
certificate (plan D3).

| Option | Real permissions and apps | Toni's data safe | Disturbs Toni | Speed | Once for Toni |
|---|---|---|---|---|---|
| A. Dev copy in Toni's account | yes | only for files (fixture folder), shell, own browser | two menu icons, a first-run window | rebuild ~1 min | grant permissions |
| B. Separate macOS test user on his Mac | yes, every capability with test data | yes | an unlocked run needs a user switch (takes the screen) | fast | make the account, grant |
| C. Tart VM with the local build | yes inside the guest | yes (nothing of the Mac goes in) | no | image once; a copy starts in ~1–3 min, can stay up through a session | run `eval-image.sh`, approve permissions in the guest |
| D. In-process test host (today's `e2e mac`) | WebKit, files, shell; no app start or permissions | no on his Mac (real home folder) | no | ~5 min with build | — |

None of them gives the lid closed, his real accounts, or iMessage (absent or unreliable in a
VM): those stay Toni's runs.

## 4. CLAUDE.md audit

Guidance (code.claude.com/docs memory and best practices; Anthropic, "Effective context
engineering"): under 200 lines (it is loaded in every session; adherence drops with length);
only what Claude can't derive from the repository; concrete, checkable rules; what must always
or never happen goes into a hook or a permission rule, not prose; no contradictions ("Claude may
pick one arbitrarily"); history and dated quotes belong elsewhere; emphasis (IMPORTANT) sparingly;
the repository's CLAUDE.md reaches cloud sessions, `~/.claude/CLAUDE.md` does not.

Today: 306 lines, 3,400 words, plus 265 lines of `.claude/rules/`. Found:

| # | Finding | Where | Kind |
|---|---|---|---|
| 1 | "Open its pull request as soon as there is a commit" and "Open PRs only when asked" | Git | contradiction |
| 2 | Capability order "files, Notes + iMessage, shell, browser and computer control": all built (specs to 015) | Development process 6 | stale |
| 3 | Owner setup: done 2026-11-23 | Owner setup | stale (one-time) |
| 4 | The Mac's stopgap updater (`auto-update.sh`) "until Sparkle runs"; STATUS: never set up | Every finished batch ships 5 | stale |
| 5 | Every Mac-visible issue needs a `cases.json` case; `state-check` hasn't run since 2026-11-23 | Every issue becomes a regression case | rule feeds a suite nothing runs |
| 6 | Toni's standing rules ("don't ask whether", "never stop while something can move", "tests clean up") live only in `docs/cloud-sessions.md` | — | missing for both modes |
| 7 | 19 dated attributions, the Citi backstory, the list of what was removed on 2026-11-07 | throughout | history (belongs in `docs/decisions.md`) |
| 8 | "No weekly run" said three times; commands repeated from `docs/commands.md`; cloud rules split over CLAUDE.md, the start hook and `docs/cloud-sessions.md` | Done means, Every issue, Commands, Cloud sessions | duplicates |
| 9 | Cloud builds and tests the Mac app through Latchkey's `shell_run`, starts the updater through it, waits 12 minutes because "every Latchkey call counts as use" | `docs/cloud-sessions.md` | superseded by Toni 2026-11-26 (no Latchkey in development) |
| 10 | "Toni decides: ask before acting on anything not settled" next to "never ask whether or how to implement when it's clear" | Toni decides; cloud-sessions.md | tension, needs one wording |
| 11 | Rules the hooks already enforce (no stash, force-push, `git add -A`, private values) repeated in prose | Git, Nothing left behind | duplicate of a hook |
| 12 | `macos/Local.xcconfig` (STATUS) vs `macos/Config/Local.xcconfig` (CLAUDE.md, the real path) | STATUS | stale path |

## Sources

- https://code.claude.com/docs/en/memory.md; https://code.claude.com/docs/en/best-practices.md;
  https://code.claude.com/docs/en/hooks-guide.md; https://code.claude.com/docs/en/claude-code-on-the-web.md
- https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- https://www.anthropic.com/engineering/writing-tools-for-agents
- https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
- https://martinfowler.com/articles/practical-test-pyramid.html; https://martinfowler.com/bliki/ContractTest.html
- https://kentcdodds.com/blog/the-testing-trophy-and-testing-classifications
- https://engineering.atspotify.com/2018/01/11/testing-of-microservices
- https://testing.googleblog.com/2010/12/test-sizes.html (read from search excerpts; host blocked in the session)
- https://testing.googleblog.com/2015/04/just-say-no-to-more-end-to-end-tests.html
- https://testing.googleblog.com/2016/05/flaky-tests-at-google-and-how-we.html
- https://abseil.io/resources/swe-book/html/ch13.html (excerpts)
- https://go.dev/blog/testing-time; https://pkg.go.dev/testing/synctest
- https://www.jamesshore.com/v2/books/aoad1/ten_minute_build
- https://github.com/cirruslabs/tart; https://circleci.com/docs/testing-macos
- https://modelcontextprotocol.io/docs/tools/inspector; https://github.com/modelcontextprotocol/conformance
- https://arxiv.org/abs/2406.13352 (AgentDojo)
- https://microsoft.github.io/code-with-engineering-playbook/automated-testing/synthetic-monitoring-tests/

## 5. CI time, push to last check (measured 2026-11-26, FR-1612)

From the workflow runs' created time to the last check's end, per commit (`gh api
repos/tonimelisma/latchkey/actions/runs?head_sha=…`):

| Commit (pull request head) | macos/ changed | Push → all done | Longest workflow | Why |
|---|---|---|---|---|
| 580388a | yes | 4 m 45 s | e2e 4 m 45 s, mac build 4 m 31 s | nothing else running |
| 83b746a | yes | 8 m 13 s | e2e 8 m 13 s | e2e-mac waited for a free macOS runner |
| 00f21a0 | yes | 14 m 28 s | mac build 14 m 28 s | runners busy with another run |
| 3e99547 | yes | 16 m 37 s | mac build (one job) | before the four-job split |
| c513a21 | no | 2 m 53 s | relay 2 m 35 s | no Mac work |

Per job: each Mac build-and-test job 3 m 56 s to 6 m 30 s (build ~1.5 min of it), e2e-mac
3 m 3 s to 4 m 8 s after `pick` (47 s), relay tests 2 m 5 s to 2 m 57 s, linux 33 to 52 s,
scripts 41 to 65 s. Every pull request push ran `ci.yml` twice (push and pull request) until
this spec.

The limit: GitHub's plan runs at most five macOS jobs at once for the account. A Mac change
takes all five (four build-and-test jobs and e2e-mac), so a second push, another session's pull
request, or main's run after a merge waits for a runner: that wait, not the tests, is what
passes 5 minutes.

## 6. The sandbox's implementation choices (T11, T12; 2026-11-26)

Low-level choices made while writing `macos/scripts/sandbox.sh` and `cmd/e2e sandbox`
(CLAUDE.md: decided, recorded here). None is verified on a Mac yet.

- **Where the relay runs.** (a) On the host, the copy dialing out to it: the image would have to
  be paired again with a host address, and the host would serve the copy. (b) Inside the copy,
  the relay the image was paired with (`prepare`, as the evals do). Chose (b): no new pairing,
  nothing of the host in the loop. The relay listens on 8444 behind a proxy on 8443, the address
  Latchkey dials, so a check can cut the network silently (maccheck's proxy, which now also
  passes a close on, so a relay restart is seen at once).
- **What the build copies.** (a) Build in `macos/` (Xcode reads `Config/Local.xcconfig` through
  `#include?`, bringing the owner's team and relay); (b) a copy of `macos/` without git-ignored
  files (`git ls-files -co --exclude-standard`). Chose (b), with a guard that stops if the copy
  holds a `Local.xcconfig`. Also passed: `SPARKLE_PUBLIC_ED_KEY=` (no update key, so the copy
  never replaces the build with a release) and `LATCHKEY_DEFAULT_RELAY_HOST=`.
- **The Release identifier on the host.** The build is `net.melisma.latchkey`, like the
  installed app: it is taken out of Launch Services (`lsregister -u`) after each build and its
  folder carries `.metadata_never_index`, so nothing on the host opens it in place of the
  installed Latchkey. Never launched on the host.
- **Turning a capability off in the installed app.** No control file there (the Swift host test
  had one): Latchkey is quit, `capabilityLevels` gets `files = off` with `defaults`, and it
  starts again; the settings are exported first and imported after (also at the next start, if a
  run stopped half-way).
- **Moved from maccheck, changed.** Reconnect after the network returns: no network change
  reaches the copy, so SC-05's 10 s can't apply; the check allows 90 s and prints the time.
  Suspension lifted: the app retries every 5 minutes, or on a wake or network change; the check
  restarts Latchkey instead of waiting (the pairing kept is what it shows). Battery: compared
  with `pmset` from the state line; in a VM, no made-up percent.
- **Signatures in one image.** macOS files permissions and the login keychain's pairing item
  under the app's signature, one signature per bundle identifier. So the image is approved and
  paired with the sandbox-signed build; `evals.sh --release` (CI's signature) may find the
  permissions missing or the pairing unreadable. To be checked on the first Mac run.

Not yet ported from `relay/e2e/sandbox-checks.md`: the Safari checks, the per-capability
state-check groups beyond one round trip each (notes, calendar, reminders, contacts, files,
shell, browser), maps, sweep, front-app-unchanged, no-permission-prompts, and the regression
cases listed there.

### After spec 016's CI changes (pull request #60, 2026-11-26)

| Commit | Push → all done | Mac jobs (start → end) | Wait for a Mac machine | Notes |
|---|---|---|---|---|
| 6c46064 | `mac` passed 15 s after the push | none started | none | no `macos/` change: the gate's skip path |
| 139a3d3 | 7 m 22 s | 3:56 to 4:35 each; job 1 queued 2 m 40 s | runners held by the run that push cancelled | the changes job took 52 s (Go for the pick) |
| ce45efa | 8 m 16 s | job 1 4:13, job 3 5:08 (end-to-end inside), job 2 5:22, job 0 3:45 | job 0 queued 4 m 17 s, with nothing else of this repository running | the changes job 5 s; ci 2 m 47 s; e2e-linux 2 m 31 s |

Without the wait, ce45efa comes to about 5 m 25 s (the slowest job plus the changes job and
the gate). What is left over 5 minutes, and why:

- **Another job held two of the account's five macOS machines** (GitHub's limit is per
  account, across all its repositories): nothing in this repository can prevent that wait.
- **Each Mac job builds the app itself** (1:06 to 1:50 with the compilation cache): four jobs,
  four builds. Sharing one build between jobs means uploading and downloading the build
  products (several hundred MB), which costs about what it saves.
- **GitHub's macOS runners vary** by about a minute for the same work (job 2: 4:20 in one run,
  5:22 in the next).
- **The pages tests are the bulk** (about 10 minutes of test time across the jobs): faster
  only by making those tests faster, or by more jobs side by side.

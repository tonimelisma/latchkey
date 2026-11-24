# Spec 015 research: end-to-end tests and evals

Done 2026-11-24 for the backlog item "End-to-end testing and evals" (Toni, 2026-11-23). Sources
are listed with each finding; anything marked "to confirm" is checked again when its task is
built.

## What Latchkey already has

- `relay/cmd/localcheck`: private relay on localhost, sign-up and pairing in headless Chrome, a
  pretend Mac (`relay/internal/testagent`), then real Claude Code non-interactively
  (`relay/internal/e2e/claude.go`) with a real OAuth token. `linuxcheck`: the real Linux program
  in a Debian container with systemd, driven by a real MCP client, optionally real Claude.
  `guidecheck`: a relay set up by the setup guide. `maccheck`: the Mac app's real connection
  code (`macos/Tests/LiveRelayTests.swift`) against a private relay.
- `macos/scripts/state-check/cases.json`: 22 groups of written cases (per capability,
  regressions by area, a sweep); not run since 2026-11-23. A separate session is adding unit or
  CI tests for the regression cases (`docs/regression-coverage.md`, branch `regression-tests`).
- Full traces of every tool call on each side "for evals" (spec 001 FR-680 to FR-689).
- `mac-build.yml`: builds the Mac app on `macos-26` for macOS changes; the whole unit suite runs
  there reported, not a gate (about 30 tests miss timing limits on that runner).

## How others test MCP servers end to end

- Playwright MCP (github.com/microsoft/playwright, `tests/mcp/fixtures.ts`): hermetic tests; a
  real MCP SDK client (`Client` + `StdioClientTransport`) against the real server; pages from
  local HTTP/HTTPS test servers started by the fixture. Adopted: FR-1501, FR-1505.
- GitHub's MCP server (github.com/github/github-mcp-server): e2e with its own test token against
  the live API, irreversible tools left to unit tests; "toolsnaps", every tool's schema kept as a
  snapshot file, a change fails CI until regenerated (`UPDATE_TOOLSNAPS=true`). Adopted: FR-1504.
- MCP Inspector CLI (`npx @modelcontextprotocol/inspector --cli ... --method tools/call`): fixed
  exit codes, JSON out; good for smoke checks. Not adopted: the Go checks already hold a real MCP
  client (`github.com/modelcontextprotocol/go-sdk`), and Constitution VIII asks for no second one.

## How others run agent evals

- MCPMark: a task is an instruction, a fixed start state, and a verify script; reports pass@k and
  pass^k. MCP-Universe: rule-based evaluators. Adopted as the task format (FR-1520, FR-1522).
- macOSWorld: AWS Mac snapshots; AppleScript to set up and AppleScript True/False checks; a safety
  subset of deceptive dialogs. MacArena: UTM VMs, a fresh image copy per episode, deterministic
  checks. Adopted: fresh copy per run (FR-1512), state checks by script (FR-1521).
- AgentDojo: injected content in fixtures; utility(pre, post) and security(pre, post) checks.
  Adopted: FR-1524.
- tau-bench: final database state compared with the goal state; pass^k shows how reliable an agent
  is across tries. Adopted: FR-1522 (k = 3, Toni 2026-11-24).
- LLM judges are unreliable (2026 audit of judge agreement): score on state first, tool-call rules
  (required / forbidden / unneeded) second, a judge only where state can't show the outcome. No
  task in this spec needs a judge; one that would is raised with Toni first.
- Anthropic, "Writing tools for agents": many realistic tasks with checkable outcomes; track tool
  calls, tokens, and errors; keep a held-out set so descriptions aren't tuned to the test.
  Adopted: FR-1522, FR-1526.

## Claude Code on Toni's subscription

- `claude -p` draws from the subscription when signed in (support.claude.com article 15036540).
  `claude setup-token` makes a one-year token "for CI pipelines and scripts", read from
  `CLAUDE_CODE_OAUTH_TOKEN`; `anthropics/claude-code-action` takes it as
  `claude_code_oauth_token`.
- Flags: `--output-format stream-json --verbose` gives every tool_use and tool_result,
  `system/init` with each MCP server's status (fail the run when Latchkey didn't load, FR-1523),
  and `result` with permission_denials, turns, and usage. `--mcp-config` with
  `--strict-mcp-config` (only Latchkey), `--allowedTools "mcp__latchkey__*"`, no built-in tools,
  `--max-turns`, an isolated `CLAUDE_CONFIG_DIR`.
- Pitfalls: not `--bare` (it ignores the OAuth token); no `ANTHROPIC_API_KEY` in the environment
  (it wins over the token and would bill API credits).
- Limits: the plan's rolling 5-hour and weekly windows, shared with Toni's own chats; the terms
  assume ordinary individual use, so the suite stays small and capped (about 60 runs a week,
  one hour; Toni 2026-11-24).

## A throwaway Mac

- GitHub's macOS runners: free for a public repository; a logged-in GUI session (WKWebView
  works); TCC grants only to bash, osascript, Terminal; SIP state not guaranteed; editing TCC.db
  is flaky; no lock screen, no Messages or iCloud, no nested VMs. Good for: Latchkey's own
  browser on local pages, files, shell, the relay, typing into local sign-in forms, downloads.
  Not for: Notes, Calendar, Reminders, Contacts, Messages, Mail, computer control, anything
  needing Full Disk Access or Screen Recording (FR-1506 lists them as skipped).
- Tart (cirruslabs/tart) golden VM on Toni's Mac: Apple's advice is to approve the app's
  permissions once in the VM, shut it down, and clone per run (developer.apple.com/forums/thread/
  834560). Screen Recording can't be pre-granted, only approved by hand once. macOS's licence
  allows two macOS VMs at once per Mac. The VM can lock its screen (whether that equals a real
  lock for Latchkey is unverified); no lid; iMessage in a VM is unreliable. Latchkey's code
  signature must stay the same or macOS asks again: the VM installs signed releases (Toni's
  development certificate), never ad hoc builds. Tart's licence is Fair Source (free under a
  CPU-core limit far above one Mac; to confirm); it is a tool on Toni's Mac, not shipped, so
  Constitution IX's licence rule (relay and app) doesn't apply. Lume (MIT) is the fallback.
- A second macOS user on Toni's Mac: rejected (Full Disk Access is system-wide, so tests could
  read Toni's data; fast user switching locks his session; Constitution IV).
- Never testable outside Toni's real Mac: lid closed, Latchkey's behavior while his Mac is locked,
  real iMessage, real sites' bot walls (FR-1541).

## Decisions taken by Claude (low-level; CLAUDE.md "Toni decides")

1. **Where Claude Code and the relay run in the weekly run.** (a) On Toni's Mac, reaching into
   the VM: Claude's process sits in Toni's session, and his Mac needs the relay's port. (b) Inside
   the test Mac: everything of the run lives in the copy and goes with it. Chosen: (b), FR-1512,
   FR-1514. The token is passed into the copy for the run only.
2. **Where the token lives on the Mac that runs the tests.** (a) A file: readable by anything
   the person runs. (b) Their login keychain (service `latchkey-eval-claude-token`), read by the
   start script. Chosen: (b), set once (`claude setup-token`, pasted at the image script's
   password prompt).
3. **How the weekly results fit the intake's 64 KB entries** (only when sent, FR-1530). (a) Change the intake's limit:
   touches spec 014. (b) Send a summary (per task: passes, calls, errors, tokens; failed tries'
   tool calls cut to fit), compressed, split into several entries when larger, each sealed to the
   developer's key with `kind: "eval"` inside the sealed part. Chosen: (b); the intake stays as it
   is and can't tell results from reports.
4. **How the real Mac app's tools run on GitHub's runner without a person.** (a) A URL-scheme
   pairing link: the app asks the Owner (FR-054a), a dialog the runner can't answer, and release
   builds refuse a relay without TLS (FR-054b). (b) A Debug-only launch setting that pairs
   without asking: a new pairing path in the app, needing a security review, for a test. (c) A
   Swift test hosted by the app, as `LiveRelayTests` already is for `maccheck`: it pairs with
   `PairingFlow.exchange(save: false)` and serves the app's real capabilities
   (`AppModel.makeCapabilities()`, the same tools, handlers and descriptions) through the real
   `RelayConnection`. Chosen: (c), no change to the app; what it doesn't cover (the menu, the
   app's own pairing and permissions screens) is unit-tested already and covered weekly by the
   installed release in the test Mac.
4a. **How the installed release in the test Mac is paired without a person each week.** The
   release refuses a relay without TLS, and a pairing link asks the Owner. Chosen: pair once,
   while the image is prepared (one Connect click with the permissions): the image holds a
   private relay's database, a test certificate authority trusted by the test Mac (the relay
   answers at `https://relay.latchkey.test:8443`, a name only that Mac resolves), and the
   account's passkey exported from Chrome's virtual authenticator. Each copy starts that relay
   from the stored database, adds the stored passkey to a new virtual authenticator, signs in
   and approves a fresh client token: the real sign-in and OAuth flows, no stored token.
4b. **The base image.** Cirrus Labs' `ghcr.io/cirruslabs/macos-tahoe-base` (macOS 26; SSH on,
   user `admin`; to confirm at build time). Chrome for Testing's headless shell and Claude Code
   are installed into it by the image script; the `e2e` program is built for darwin/arm64 from
   the clone and copied in each run, so the run always uses the clone's own code.
5. **The path-to-capability map.** One file, `relay/e2e/capabilities.json` (paths as globs, each
   capability's checks); shared paths select everything. Chosen over per-check annotations so
   one file says what runs.
6. **How a required check works with path filters.** GitHub blocks a pull request whose
   required check never runs, so each e2e job always runs, picks its work from the map, and
   passes at once when nothing is selected (FR-1502).
7. **Fixture data.** Made by scripts in the test Mac image (Notes, Calendar, Reminders, Contacts,
   files, a test keychain of fake sign-ins for local pages), each tagged so a sweep removes any
   left behind; pages served by the check. Never a copy of real data.

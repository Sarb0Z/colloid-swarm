# Handoff: 2026-10-03 to 2026-10-04 session

## Objective

Carry every open line of work to the next session: the live QA of the
`publish-approval` mod, the mobile QA trial, the workflow router, the status
strip check, the testing write-up, and the rulings that wait on the operator.
Each section ends with its exact next action.

## Current state

Everything below is committed on `main` in `colloid-swarm`. Nothing is pushed,
so no CI run has seen any of it.

| Commit | What landed |
|---|---|
| `18f470d` | `lint-skills.sh` reads links in prose only, with `test-lint-skills.sh` |
| `de1f830`, `60f642b` | Router slice 1: `grilling` and `domain-modeling` vendored from `mattpocock/skills` (MIT), and the fork that records decisions in `decisions.md` |
| `614fa71` | `config.py` reports a `policy.json` or `config.json` that is not a readable JSON object |
| `038c7c5` | `session-start.sh`'s post-compaction text defers commit timing to the repository |
| `628530d` | Showcase cards for `denied-tool`, `grilling` and `domain-modeling`, with copy placeholders |
| `6c51eac` | Mods slice 0: P1 to P4 hold; research entry `2026-10-03-claude-code-mods-slice-0.md` |
| `2a613cb`, `025be3f` | The operator's status strip as `.agents/claude/statusline.sh`, switched by `hooks.status_strip.enabled`; decision `status-strip-as-statusline-command` |
| `92842b6` | `guard-publish` allows the one call approved in the publish dialog (token path) |
| `61d66e4` | Mods slice 1: the `publish-approval` mod, `.agents/claude/mods/`, `test-mods.sh`, and a CI job pinned to Claude Code 2.1.288 |
| `f3e0277` | The mods handoff records slice 1, P5, and the dialog's idle auto-resolve |

## 1. `publish-approval` mod: live QA

### What it does

In auto, bypassPermissions and dontAsk modes, `guard-publish` denies a push,
deploy or publish, because no permission prompt reaches the user. The mod asks
the guard by argv whether it would ask. If so, it opens Claude Code's question
dialog with the whole command and the guard's reason. "Run it" writes
`.agents/.publish-approved-<tool_use_id>`; the guard consumes it within 120
seconds and answers "allow". "Refuse" denies the call. A dismissal, typed
text, a dialog that resolved while the user was idle, or a command too long to
show leaves the guard's own answer. Full design: `.agents/claude/README.md`,
"Gating outward mutations" and "Mods".

### Evidence so far

- `claude plugin validate` and `claude plugin test` pass with no login, in a
  bare `node:24-bookworm-slim` container with Claude Code 2.1.288 from npm (P5).
- `test-mods.sh`: 13 tests pass. `test-guard-publish.py`: all pass; the token
  rows fail against the guard before `92842b6`. Strict `tsc` is clean against
  the build's declarations.
- The hostile review's two P1 findings are dispositioned. The dialog showed
  only 600 characters but approved the whole command: fixed. The token is
  forgeable by a process the model starts: accepted as debt
  `publish-token-forgeable`, pending the operator's ruling in section 6.

### The first live attempt failed

On 2026-10-04 the mod was listed as `publish-approval@skills-dir`, loaded, but
an auto-mode `git push` was denied with no dialog. Run by hand, the config read
said `yes` and the guard said `ask`. Temporary tracing to `/tmp/pa-debug.log`
wrote nothing, either after the edit or on the push.

The working theory: the mod read its switch only in `session.start`, which a
plugin loaded with the session does not see, and the traced edit never
hot-reloaded. Commit `61d66e4` now settles the switch on the first gated call,
with a test for a session that never sends `session.start`. This is unverified
live. If the next attempt also shows no dialog, the hooks are not running at
all: add a trace again and confirm that a write from the mod reaches disk.

### Next action

1. The operator restarts Claude Code in `colloid-swarm` in auto mode.
2. Run four pushes against `/tmp/pa-qa/clone`, whose `origin` is the local bare
   repository `/tmp/pa-qa/remote.git`, so nothing leaves the machine:
   - `git -C /tmp/pa-qa/clone push -u origin main`: the dialog shows; after
     "Run it" the push succeeds.
   - `git -C /tmp/pa-qa/clone push --force origin main`: after "Run it",
     `guard-destructive` still blocks it.
   - A push answered "Refuse" is denied with the refusal text.
   - With `"publish_approval": {"enabled": false}` under `hooks` in
     `.agents/config.json` and a restart, an auto-mode push is denied as before.
3. Measure the time the mod's guard probe adds to a Bash call.
4. Record the result in the mods handoff, then delete `/tmp/pa-qa`.

If `/tmp/pa-qa` is gone (macOS clears `/tmp` on reboot), recreate it: a bare
repository with `git init --bare -b main`, a clone of it, and two empty commits.

## 2. Mobile QA trial

The full plan is unchanged from the 2026-10-03 handoff, now carried here: the
candidates, scenarios, measurements, decision rule and wiring are below.

### State on 2026-10-04

- Xcode is selected, the license is accepted, and the iOS 27.0 simulator
  runtime is installed.
- Appium 3.8.0 with the xcuitest driver 12.14.1 is installed globally under
  fnm's Node 24. Maestro 2.11.0 is installed from the `mobile-dev-inc/tap`
  Homebrew tap, with Java 21.
- Android is not installed: no SDK and no `adb`.
- `teardown-gate.sh` reads every `appium` word as a server start (breadcrumb).
  Fix it before the trial, or every Appium install and driver command arms the
  gate.

### Candidates

| Tool | Role | Notes |
|---|---|---|
| `appium-mcp` | Live exploration | In `.agents/mcp.json`, off. Needs the Appium server and WebDriverAgent, whose first build is slow. |
| `@mobilenext/mobile-mcp` | Live exploration | Read its README for its requirements before the first run. |
| Maestro | Committed end-to-end check | YAML flows in `.maestro/`. Check whether it ships an MCP server; if it does, it is also a live-exploration candidate. |

### Target: MemoGo

`~/Projects/MemoGo/mobile-app`, branch `main`. Expo 56, React Native 0.85,
`expo-router`, `expo-dev-client`, a prebuilt `ios/`, bundle ID `com.memogo.app`,
bun. The backend is local Supabase (`bun run db:start`), which needs Colima
running. Build with `bunx expo run:ios --configuration Release`, so no Metro
server is needed. Follow MemoGo's own `AGENTS.md` for anything that lands
there.

### Scenarios (the same for every tool)

1. A cold launch reaches the first screen.
2. Sign up, then sign in, against the local Supabase.
3. Create a memo, and see it in the list.
4. Quit and relaunch the app, and the memo is still there.
5. A deliberate obstacle, such as a permission dialog or the backend offline.
   The agent must report it as a finding, not work around it.
6. Teardown: the simulator, the Appium server and every process the run started
   are stopped.

### Measurements and decision rule

Per tool: operator steps to the first passing run; tool count and schema size in
the subagent (mods plan M7); pass rate over 5 runs of scenarios 1 to 4; tokens
per scenario; accessibility tree or screenshots only; teardown completeness;
whether it drives Flutter apps, from its documentation.

- Live exploration: the server with the fewest operator steps that passes 4 of
  5 runs and reports the scenario-5 obstacle; on a tie, the smaller tool list.
- Committed check: adopt Maestro when flows for scenarios 1 to 4 run from one
  command with no human step; otherwise record why, and whether Detox is worth a
  trial.

### Wiring after the decision

A `mobile-verifier` persona whose `mcpServers` names only the chosen server;
`qa-verifier.md`'s hand-off line names it; the chosen server in `.agents/mcp.json`,
off by default, and the losing entry removed; the server's session tools in the
`teardown-gate` matcher, classification and test; `test-mcp.sh` and
`test-permissions.sh` updated; `stack-expo.md` names the Maestro flow location
if adopted; a dated research entry with the measurements.

### Next action

Fix the `teardown-gate.sh` Appium reading. Then, in a session started in
`~/Projects/MemoGo/mobile-app` with Colima running, run
`python3 .agents/mcp.py enable appium-mcp`, add mobile-mcp the same way, restart
the session, and run the scenarios.

## 3. Workflow router

- Plan: `docs/handoff/2026-10-03-workflow-router.md`. Slice 1 has landed.
- Slice 2 is the router as one unit: the router and "Rules for every workflow"
  sections of `AGENTS.md`, the ten workflows (five inline, five playbooks), the
  review-of-the-review pass, a probe of plan-mode approval in auto mode, and an
  operator command that runs `grilling` and `domain-modeling` together. The six
  steps leave in the same commit.
- It changes the root contract, so it is critical: plan mode, a plan review, and
  the operator's OK before code.
- Gate before the next satellite sync: `merge-kit.py` must keep the
  satellite-owned paragraphs inside `## Workflow`. `~/Projects/Incura/clearclaim`
  holds one.
- Next action: enter plan mode for slice 2.

## 4. Status strip

- `.agents/claude/statusline.sh` draws the operator's two-row strip in every
  scaffold repository; with `hooks.status_strip.enabled` off, the person's own
  status line runs instead. 12 test cases, in CI.
- Unconfirmed: the operator has not said whether the live strip looks right (two
  rows, a yellow "● WORK" at the left).
- `~/.local/bin/claude-statusline.sh` still draws in repositories without the
  scaffold, so two copies exist.
- Next action: the operator confirms the look, and says whether the personal
  copy should point at the scaffold's.

## 5. Testing write-up

Inputs: `docs/handoff/2026-10-03-testing-writeup-inputs.md`. The operator
writes the write-up; testing rules are adopted only after it lands.

## 6. Rulings that wait on the operator

- **Forgeable approval token.** Accept as debt `publish-token-forgeable` (the
  current state), or make it unforgeable with Claude Code's Bash sandbox
  (`denyWrite` on `.agents/.publish-approved-*` plus deny rules for Write and
  Edit), a few hundred lines and a new review.
- **A malformed `policy.json`.** `config.py` now reports it, but the publish
  guard's script list is still empty while it is broken, so listed deploy
  scripts run without an ask. Should the guard ask on everything until it
  parses? (Open decision in `breadcrumbs.md`.)
- **Showcase copy.** Three placeholders in `demo/scaffold-showcase.html` wait
  for the operator's text: `[denied-tool card — what it does for the reader, one
  or two sentences]`, `[grilling card — what it does for the reader, one
  sentence]`, `[domain-modeling card — what it does for the reader, one
  sentence]`.
- **The nine MCP deny rules.** In a fresh session, does `/permissions` list all
  nine?
- **The upstream bug report** (a bare `permissions.deny` does not remove an MCP
  tool from a subagent that names the server): draft only when the operator
  asks; filing publishes under the operator's account.

## 7. Cleanup

- `/tmp/pa-qa`: delete after the live QA in section 1.
- `/tmp/workflow-mining` is already gone (checked 2026-10-04).
- The Docker image `node:24-bookworm-slim` (351 MB) was pulled for the P5 probe.
  Remove it with `docker image rm node:24-bookworm-slim` if nothing else uses it.

## Limitations

- The mod has not run live; every claim about it comes from the engine's test
  kit and the type declarations.
- The CI job for mods has not run, because nothing is pushed.
- A mod type-check needs the declarations Claude Code writes when a mod loads or
  the plugin-authoring skill runs, so `test-mods.sh` does not type-check.

## Next action, in order

1. The operator restarts Claude Code in auto mode; the agent runs the
   `publish-approval` live QA (section 1).
2. The agent fixes the `teardown-gate.sh` Appium reading, then runs the mobile
   trial on MemoGo (section 2) in a window with Colima up.
3. The agent starts router slice 2 in plan mode (section 3).
4. The operator answers the rulings in section 6 when convenient.

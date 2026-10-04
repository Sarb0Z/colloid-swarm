# Handoff: 2026-10-03 to 2026-10-04 session

## Objective

Carry every open line of work to the next session: the live QA of the
`publish-approval` mod, the mobile QA trial, the workflow router, the status
strip check, the testing write-up, and the rulings that wait on the operator.
Each section ends with its exact next action.

## Current state

Everything below is committed on `main` in `colloid-swarm`. Commits through
`1346346` are pushed and CI passed on them, the mods job included.

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
| `b6b3e61` | `teardown-gate.sh` records an Appium server only when `appium` is the command run |
| `cdda55f`, `c5addb7` | The mod logs a non-approving dialog answer; the Claude adapter passes `tool_use_id` to the publish guard |
| 32 commits after `0a1560b` | Breadcrumb burndown: guards, gates, Codex, MCP servers, export kit, Flutter pack and Dart check; review in `docs/reviews/2026-10-04-burndown.md` |
| `fa2ab68`, `386de30`, `342aeb0` | Tests clear `GIT_*` before running git (with `check-test-isolation.py`); settings ask rules for the new deploy verbs; tier-neutral delegation line |

## 1. `publish-approval` mod: done

The live QA passed on 2026-10-04; the result is in the mods handoff, slice 1.
The QA found that the Claude adapter dropped `tool_use_id`, so no dialog
approval could match its token (`c5addb7`). A debug-log line now records a
dialog answer that is neither "Run it" nor "Refuse" (`cdda55f`). Mods slice 2
(M3, the delegation gate) is next in `docs/handoff/2026-10-02-claude-code-mods.md`.

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
- `teardown-gate.sh` records an Appium server only when `appium` is the command
  run, bare or as `server`. An install and the driver, plugin and setup
  subcommands do not arm it.

### Candidates

| Tool | Role | Notes |
|---|---|---|
| `appium-mcp` | Live exploration | In `.agents/mcp.json`, off. Needs the Appium server and WebDriverAgent, whose first build is slow. |
| `@mobilenext/mobile-mcp` | Live exploration | Read its README for its requirements before the first run. |
| Maestro | Committed end-to-end check | YAML flows in `.maestro/`. Check whether it ships an MCP server; if it does, it is also a live-exploration candidate. |

### Target: Meridian (held by the operator)

The operator moved the trial to `~/Projects/Meridian/meridian-profit-mobile-app`
on 2026-10-04, then held it. Branch `main`. Expo 54, React Native 0.81,
`expo-router`, `expo-dev-client`, a prebuilt `ios/`, bun, Clerk sign-in. Its
`.env` points at the hosted staging API (`api-staging.meridianprofitsapp.com`)
and a Clerk test instance (`pk_test`), so sign-in, sign-up and any created data
reach hosted services. Its `AGENTS.md` already names Appium MCP as the only
device surface. `node_modules` is installed; `ios/Pods` is not.

- Before any run: the operator rules how far the trial may go against staging
  (read-only sign-in with a test account, creating data, signing up, or a local
  backend), and where the test account's credentials live.
- Build with `SENTRY_DISABLE_AUTO_UPLOAD=true`: the Release build's Xcode phase
  otherwise uploads debug files to Sentry.
- Scenarios 2 to 4 map to sign in, add a service (only if the ruling allows a
  write), and relaunch.

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

Ask the operator for the staging ruling above. Then, in a session started in
`~/Projects/Meridian/meridian-profit-mobile-app`, enable `appium-mcp` there, add
mobile-mcp the same way, restart the session, and run the scenarios.

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

- `/tmp/workflow-mining` is already gone (checked 2026-10-04).
- `/tmp/pa-live.txt`: the debug log of the session that ran the live QA. Delete
  it once that session is restarted without `--debug-file`.
- The Docker image `node:24-bookworm-slim` (351 MB) was pulled for the P5 probe.
  Remove it with `docker image rm node:24-bookworm-slim` if nothing else uses it.

## Limitations

- A mod type-check needs the declarations Claude Code writes when the
  plugin-authoring skill runs or a mod loads from a `--plugin-dir` folder. A mod
  loaded from `.claude/skills/` gets none (observed 2026-10-04), so
  `test-mods.sh` does not type-check.
- The off-switch check ran in a headless session, not an interactive restart.

## Next action, in order

1. The operator rules on the Meridian mobile trial's use of staging (section
   2); then the agent runs it.
2. The agent starts router slice 2 in plan mode (section 3).
3. The operator answers the rulings in section 6 when convenient.

# Handoff: 2026-10-02 to 2026-10-03 session

## Objective

Carry every open line of work from this session to the next session: the
mobile QA trial (Appium, mobile-mcp and Maestro as the mobile equivalent of
Playwright), the workflow router, the Claude Code mods, the testing write-up,
and the defects found on the way. Each section ends with its exact next action.

## Current state

Everything below is committed on `main` in `colloid-swarm`. Nothing is pushed.

| Commit | What landed |
|---|---|
| `b12fa39` | Mods migration plan `docs/handoff/2026-10-02-claude-code-mods.md`, and decision `mods-where-value-exceeds-portability` |
| `b130cbe` | Research on side-agent observers ("You should know"); an observer mod is deferred in the mods plan |
| `2f66f0c` | `denied-tool.sh`: a denied tool comes with a remedy. `qa-verifier` drops `browser_run_code_unsafe` through `disallowedTools`. `test-permissions.sh` gates both. |
| `d60c9e3` | Research on tool-list pruning, and plan item M7 (always-on pruning) |
| `3075ef3` | Research on the workflows mined from 473 session episodes |
| `16c53bd` | TypeScript, Python and Rust stack packs from `claudestd` (CC0). `check-stack-packs.py` ignores files under `.agents/`. |
| `0503602` | `AGENTS.md`: "Errors fail loudly" and "Commits split along seams" |
| `bb1169b`, `9e2f5be` | Breadcrumbs: the `AGENTS.md` size, the `config.py` defect and the teardown signal |
| `3359538`, `53992fa` | Testing rules held for the operator's write-up; inputs in `docs/handoff/2026-10-03-testing-writeup-inputs.md` |
| `eb46306` | Workflow router plan `docs/handoff/2026-10-03-workflow-router.md`, settled with the operator |

## 1. Mobile QA trial

### Goal

Playwright has two roles here:

- **Live exploration.** The `playwright` MCP server lets a QA agent drive a
  browser.
- **A committed end-to-end check.** A Playwright test that an agent runs to
  learn whether it broke the product.

The trial picks the mobile tool for each role and wires the winner into the
scaffold.

### What exists today

- `.agents/mcp.json` registers `appium-mcp` (`npx -y appium-mcp`), off by
  default.
- `.agents/personas/qa-verifier.md` says "Mobile/device work belongs to a generic
  Appium-equipped verifier", but no such persona exists.
- `teardown-gate.sh` already recognizes Appium session tools.
- Measured on 2026-10-03:
  - Appium was called 0 times across all of this machine's Claude transcripts.
  - The mobile satellites (MemoGo, bitely-app, Meridian mobile) enable only
    `context7`, `playwright` and `research-mcp`.

### Candidates

Versions and stars are from npm and GitHub on 2026-10-03.

| Tool | Role | Source | Notes |
|---|---|---|---|
| `appium-mcp` | Live exploration | `appium/appium-mcp`, npm 1.95.1, about 485 stars | Needs an Appium 2 server, the XCUITest driver (and UiAutomator2 for Android), and WebDriverAgent, whose first build is slow. Already in the registry. |
| `@mobilenext/mobile-mcp` | Live exploration | `mobile-next/mobile-mcp`, npm 1.0.8, about 8.6k stars | Its description: "Mobile Automation and Scraping (iOS, Android, Emulators, Simulators and Real Devices)". Read its README for its requirements before installing; they are unverified here. |
| Maestro | Committed end-to-end check | `mobile-dev-inc/maestro`, about 16k stars | A CLI with YAML flows in `.maestro/`. Check whether it ships an MCP server. If it does, it can also be a live-exploration candidate. |

### Machine prerequisites (the operator runs these)

These are admin changes. Run them in a real terminal, or add them to
`~/.config/macos-admin.sh`; `sudo` cannot prompt from an agent's shell.

1. `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. On
   2026-10-03 the active developer directory was `/Library/Developer/CommandLineTools`,
   so `xcrun simctl` was not available.
2. `sudo xcodebuild -license accept`, then open Xcode once so that it installs
   its components. Install an iOS simulator runtime (Xcode > Settings >
   Components).
3. Check: `xcrun simctl list runtimes` lists an iOS runtime, and
   `xcrun simctl list devices available` lists an iPhone.
4. Android is a second phase. Install Android Studio, the SDK and one emulator
   image, then check that `adb devices` runs. On 2026-10-03 there was no
   Android SDK and no `adb`.
5. Approve the local installs that the trial makes: the Appium server and its
   driver, the mobile-mcp package, and the Maestro CLI. The trial installs
   nothing without that approval.

### Trial target: MemoGo

The app is at `~/Projects/MemoGo/mobile-app`, on branch `main`.

- The stack is Expo 56 with React Native 0.85, `expo-router` and
  `expo-dev-client`, with a prebuilt `ios/` directory and no `eas.json`. The
  bundle ID is `com.memogo.app`, and the package manager is bun.
- The backend is a local Supabase (`bun run db:start`), which needs Docker. On
  this machine Docker is Colima, which the operator stops while running local
  models. Agree on a window with Colima up.
- Build a simulator app with `bunx expo run:ios --configuration Release`. A
  Release build needs no Metro server, which keeps the runs repeatable. Use the
  dev-client build only for a scenario that needs live reload.
- Follow MemoGo's own `AGENTS.md`, including its commit rules, for anything
  that lands there, such as Maestro flows.

### Scenarios (the same for every tool)

1. A cold launch reaches the first screen.
2. Sign up, then sign in, against the local Supabase.
3. Create a memo, and see it in the list.
4. Quit and relaunch the app, and the memo is still there.
5. **A deliberate obstacle**, such as a permission dialog or the backend going
   offline. The pass condition is that the agent reports the obstacle as a
   finding. It must not work around it by changing data, state or settings.
   This tests the incident in the testing inputs.
6. Teardown: the simulator, the Appium server and any other process the run
   started are stopped.

### Measurements

For each tool, record:

- the operator steps and the setup cost up to the first passing run;
- the number of tools it adds and their schema size in the subagent (plan item
  M7);
- the pass rate over 5 runs of scenarios 1 to 4, which shows flakiness;
- the tokens used per scenario;
- whether it reads the accessibility tree or only screenshots;
- teardown completeness;
- whether it can drive the Flutter apps (`~/Projects/Bitely/bitely-hub`,
  `~/Projects/GymRobot/gymrbt-flutter`), as a yes or no from its documentation.
  This needs no run.

### Decision rule

- **Live exploration:** take the server with the fewest operator steps that
  passes at least 4 of 5 runs of scenarios 1 to 4 and reports the scenario-5
  obstacle. On a tie, take the smaller tool list.
- **Committed check:** adopt Maestro when its flows for scenarios 1 to 4 run from
  one command with no human step. Otherwise record why, and whether Detox is
  worth a trial.

### Wiring after the decision

- A new persona, `.agents/personas/mobile-verifier.md`. Its `mcpServers` names
  only the chosen server, so its tools load into that subagent alone. It
  carries the same contract as `qa-verifier`. Its tool budget follows M7.
- `qa-verifier.md`: the hand-off line names `mobile-verifier`.
- `.agents/mcp.json`: an entry for the chosen server, off by default. Remove an
  entry that lost the trial, such as `appium-mcp`.
- `teardown-gate`:
  - Add the chosen server's session tools to the `PostToolUse` matcher in
    `.agents/claude/settings.json` and to the classification in
    `teardown-gate.sh`.
  - Add a row in `.agents/test-teardown-gate.sh`.
- `.agents/test-mcp.sh` and `.agents/test-permissions.sh`: update for the new
  entry and persona.
- `.agents/rules/stack-expo.md` names where Maestro flows live, if Maestro is
  adopted.
- A dated entry in `.agents/knowledge/research/` with the measurements, and a
  line in its index.
- Satellites: enable the server per mobile satellite at its next sync. It stays
  off elsewhere.

### Next action

The operator runs prerequisites 1 to 3 and approves the installs (prerequisite
5). Then, in a session started in `~/Projects/MemoGo/mobile-app`, run
`python3 .agents/mcp.py enable appium-mcp`, add mobile-mcp the same way,
restart the session, and run the scenarios.

## 2. Workflow router

- **Plan:** `docs/handoff/2026-10-03-workflow-router.md`. The AI review was
  adopted (7 P1, 5 P2), and the operator settled four questions:
  - the agent picks the workflow and stakes, and the operator overrides;
  - each product repository keeps a glossary, and decisions stay in
    `decisions.md`, not in ADRs;
  - commits land per chunk at every stakes level;
  - critical scaffold work is the guard and gate hooks and the contract.
- **Slices:**
  1. Vendor `grilling` and `domain-modeling` from `mattpocock/skills` (MIT),
     with `GLOSSARY-FORMAT.md`, without `ADR-FORMAT.md`, and with the fork
     recorded.
  2. The router as one unit.
  3. Make `session-wrap` read the workflow and the stakes.
  4. Skills for the re-typed procedures.
- **Gate before the next satellite sync:** `merge-kit.py` must capture the
  satellite-owned paragraphs inside `## Workflow`. clearclaim holds one.
- **Next action:** slice 1. It needs no authorization.

## 3. Claude Code mods

- **Plan:** `docs/handoff/2026-10-02-claude-code-mods.md`. Candidates M1 to M7
  and the deferred observer.
- **Slice 0 blocks M1 to M6.** It probes the platform with the throwaway mod at
  `/Users/mac/.claude-personal/dev-mods/15e206e3-6ad1-40b6-90a5-61075d8dcabc/modprobe`,
  which loads when this session restarts:
  - P1: `$.ui.ask` holds an auto-mode Bash call;
  - P2: the dialog shows for a subagent's call;
  - P3: the `tool_use_id` matches the settings-hook payload;
  - P4: a mod loads from a project skills folder;
  - P5: `claude plugin test` runs in CI.
  - The test command is `git push origin MODPROBE-none # MODPROBE`. It is
    harmless: the branch does not exist, so Git stops before it contacts the
    remote.
- **M7's persona and gate half needs no mod** and can start at any time. It
  adds `.agents/tool-usage.py`, persona `tools` lists trimmed to measured use,
  and a tool budget in `test-permissions.sh`.
- **Next action:** the operator restarts this session in auto mode. Then run the
  slice-0 test, record P1 to P5 in `.agents/knowledge/research/`, and delete the
  probe mod.

## 4. Testing write-up

- **Inputs:** `docs/handoff/2026-10-03-testing-writeup-inputs.md`. It holds:
  - the operator's position verbatim, including "Tests are a budget, not a
    goal";
  - the tester-subagent incident;
  - the 60-day churn per satellite;
  - the `claudestd` candidates;
  - every repository rule that touches testing;
  - the mechanism candidates.
- **Open ruling:** whether "Tests are a budget" goes into `AGENTS.md` now or
  with the write-up.
- **Next action:** the operator writes the write-up. Testing rules are adopted
  only after it lands.

## 5. Defects and fixes that are ready

Each one is a breadcrumb in `.agents/breadcrumbs.md`.

- **`hooks/lib/config.py`** treats a `policy.json` with a syntax error as empty.
  A repository that turned a hook off gets it back on, and its
  `dry_run_commands` disappear (reproduced). Report the parse error, and
  decide whether a broken policy fails closed.
- **`teardown-gate.sh`** reads any commit as "work done". Commits that split
  along seams now land mid-task, which meets the reopen condition of
  `teardown-tiered-by-restart-cost`.
- **`session-start.sh`'s post-compaction text** says "commits happen only when
  the user asks" and "a fix under ~15 minutes". The operator's router ruling
  (commit per chunk at every stakes level) unblocks the restatement.
- **`qa-verifier`'s `disallowedTools`** is unobserved, because persona files
  load at session start. In a fresh session, have a `qa-verifier` list its
  `mcp__playwright__` tools.

## 6. Waiting on operator approval

- **An upstream bug report.** A bare `permissions.deny` rule removes an MCP tool
  from the main thread, but not from a subagent whose `tools` names the server.
  The docs say the rule removes the tool "from Claude's context entirely", and
  no open issue reports this case. Filing it on `anthropics/claude-code`
  publishes text under the operator's account, so draft it only after the
  operator asks.

## 7. Cleanup

- `/tmp/workflow-mining/` holds the three mining cells' extracts. They contain
  the operator's prompt text, including two prompts with pasted secrets. Delete
  them when the operator has no more follow-up questions on the workflows.
- Delete the slice-0 probe mod after slice 0 runs.

## Limitations

- The Claude logs on this machine start around 2026-09-05. The workflow mining
  covers September onwards.
- The mobile candidates' requirements are unverified until each README is read
  and a first run is made.
- Auto-mode behavior of plan-mode approval, which the router's human gate
  depends on, is unverified. Router slice 2 probes it.

## Next action, in order

1. The operator: restart this session (mods slice 0), and run mobile
   prerequisites 1 to 3, with approval for the installs.
2. The agent: router slice 1, which needs no authorization and can run first.
3. The agent: the mobile trial on MemoGo, then mods slice 0, in whichever order
   the operator's machine is ready for.

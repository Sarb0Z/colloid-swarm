---
date: 2026-10-03
subject: Slice 0 of the Claude Code mods plan — what a scaffold mod can observe, hold and load on Claude Code 2.1.288
kind: research
source: probe runs in this repository on 2026-10-03, read from the session transcript and the engine's own validator and test runner
---

# Claude Code mods, slice 0

`docs/handoff/2026-10-02-claude-code-mods.md` names five platform questions,
P1 to P5, that must be settled before any mod slice depends on them. A
throwaway probe answered four of them in this repository on Claude Code
2.1.288, and found one platform gap that the plan had stated as a fact.

## Setup

- `modprobe`: a probe mod in the scaffold location,
  `.agents/claude/mods/modprobe/`, reached through the link
  `.claude/skills/colloid-modprobe`. It hooked `tool.call` for Bash and
  `classic.PreToolUse`, and acted only on commands that carried the marker
  `MODPROBE`.
- `modprobe-user`: the same probe under another name, in the session's
  user-owned dev-mods folder, loaded after the operator enabled hot reloading.
  Its `tool.call` hook also opened an observe-only dialog: it logged the answer
  and passed the call on unchanged.
- The test command was `git push modprobe-no-such-remote … # MODPROBE`. The
  remote does not exist, so Git fails locally without network access.
  `guard-publish` asks on it in default mode and denies it in auto mode.

## Claims

Grades: `[P]` primary read directly · `[A]` our own measurement or analysis ·
`[O]` observed by the operator, not read back by the agent.

### The four questions

- `[A]` **P4 holds.** A mod linked from `.claude/skills/<name>` into
  `.agents/claude/mods/` loaded at session start (`claude --continue`): its
  `tool.call` hook logged on the first marked call. Saving the file reloaded
  it in the running session ("reloaded (2 hooks: tool.call,
  classic.PreToolUse)"). Not tested in a fresh clone, so whether a startup
  question appears there is still open.
- `[A]` **P3 holds.** The `tool_use_id` that `tool.call` received
  (`toolu_01RvnKM6PwefKpc4pCtbaNRw`) equals the transcript's tool-use id and
  the `toolUseID` of the settings-hook result for the same call.
- `[A]` **P2 holds.** A `haiku` subagent's Bash call reached the user-folder
  mod's `tool.call` hook with the subagent's `agentId`. The mod's `$.ui.ask`
  dialog showed in the main interface and held the call for 5,270 ms, until
  the operator answered.
- `[O]` **P1 holds.** In auto mode (the guard's deny text names the mode), the
  dialog that `tool.call` opened appeared and held the main-thread call until
  the operator clicked "Continue". Then `guard-publish` denied the call. The
  agent could not read the log: the auto-mode classifier refused the
  transcript read.
- **P5 is untested.** `claude plugin test` ran locally in about 0.2 s with a
  logged-in account; a runner with no login was not tried.

### What the plan had wrong

- `[A]` **A mod's `classic.PreToolUse` hook is never called in a live
  session.** Neither copy logged the hook's first line on four marked calls,
  in default and in auto mode. The first line logs before any statement that
  could throw. `claude plugin validate` lists the hook, the reload line names
  it, and `claude plugin test` calls it: in the test the hook logged its entry,
  read the stand-in "ask" beneath it, and opened one dialog.
- `[P]` The API declaration says the opposite: classic events fire "wherever
  the engine runs the classic hook, whether or not any settings hook is
  configured" (`claude-code.d.ts`, `ClassicEventName`). The gap is in the live
  engine, or undocumented.
- `[A]` M1 does not need that hook. Its design runs `guard-publish` by argv
  from `tool.call` and hands the guard a token, which needs only P1, P2 and P3.

### Other observations

- `[A]` A settings-hook deny reaches a mod's `tool.call` as an errored result
  (`isError=true`), not as a `deny` field.
- `[A]` In the `tool.call` chain the user-folder mod ran above the scaffold
  mod: `modprobe-user` answered its dialog before `modprobe` logged the call.
  A mod the operator installs wraps a mod the repository ships.
- `[A]` The auto-mode classifier refused three agent actions as "Auto-Mode
  Bypass": writing a probe that turns a hook's ask or deny into allow, running
  the plugin validator on it, and reading its results from the transcript. A
  `tool.call` dialog that only observes was allowed in manual mode. Work on an
  approval mod therefore runs in manual mode, each step approved by the
  operator.
- `[P]` No debug log is written without `--debug`. The reference names the
  mods folder and `--plugin-dir` folders, not skills folders, as the places
  whose hook failures reach the transcript.

## Limits

- One build (2.1.288), one machine, one account.
- P1 rests on the operator's observation; the wait time in auto mode was not
  read.
- P4 was not tested in a fresh clone or under a satellite's workspace trust.

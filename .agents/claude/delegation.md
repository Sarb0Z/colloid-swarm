# Delegation on Claude Code

The root `AGENTS.md` states delegation in host-neutral capability tiers; this
file binds them to Claude Code. `.claude/rules/delegation.md` links here without
`paths:`, so every Claude session loads it at launch. Codex binds the same tiers
in `.codex/agents/*.toml` and `.agents/codex/README.md`.

| Tier | Model |
| --- | --- |
| light | `haiku` |
| medium | `sonnet` |
| heavy | `opus` |
| frontier | `fable` |

- A generic cell is `general-purpose` with an explicit model; dispatched
  without one, it inherits the lead's model by default, and a rename runs on
  whatever tier the lead does. A named persona fixes model and effort in its
  frontmatter; use one when effort must be fixed, because a generic cell runs
  at its usual effort unless an instruction names another. The `reviewer`
  persona pins no model: the lead chooses one at dispatch, for the artifact at
  hand — a one-line diff and an architecture do not want the same reader.
- A generic cell keeps every tool, so constrain its handoff and keep the
  sandbox boundary; the handoff is the only fence it has. A generic cell that
  only reads says so by opening its prompt with `READ-ONLY`, the first line
  `parallel-writers-gate.sh` reads before it counts a cell as a writer.
- Two or more concurrent writers go through a `workloop` run;
  `parallel-writers-gate.sh` enforces it, and its denial names the commands. A
  worktree isolates the edits; only the run verifies that they compose.
- Plan mode blocks edits until the operator approves the plan, but only an
  attended terminal session offers that approval: unattended runs (`claude -p`,
  background cells) expose no plan-approval tool, and auto mode has none
  (probed 2026-10-04 on 2.1.289). The root's human gates therefore stop and
  report; plan mode is a convenience in an attended session, never the gate.

# Delegation on Claude Code

The root `AGENTS.md` states delegation in host-neutral capability tiers. This
file binds those tiers to Claude Code; `.claude/rules/delegation.md` links here
without `paths:`, so every Claude session loads it at launch. Codex binds the
same tiers in `.codex/agents/*.toml` and `.agents/codex/README.md`.

| Tier | Model |
| --- | --- |
| light | `haiku` |
| medium | `sonnet` |
| heavy | `opus` |
| frontier | `fable` |

- A generic cell is `general-purpose` with an explicit model. A named persona
  fixes model and effort in its frontmatter; use one when effort must be fixed.
  The `reviewer` persona pins no model: the lead chooses it at dispatch for the
  artifact at hand.
- A generic cell keeps every tool, so constrain its handoff and keep the sandbox
  boundary. A generic cell that only reads says so by starting its prompt with
  `READ-ONLY`.
- Two or more concurrent writers go through a `workloop` run.
  `parallel-writers-gate.sh` enforces it, and its denial names the commands.
- Plan mode blocks edits until the operator approves the plan, but only an
  attended terminal session offers that approval: unattended runs (`claude -p`,
  background cells) expose no plan-approval tool, and auto mode has none
  (probed 2026-10-04 on 2.1.289). The root's human gates therefore stop and
  report; plan mode is a convenience in an attended session, never the gate.

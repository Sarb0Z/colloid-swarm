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

- Choose the delegation's shape before dispatching, by the workloop skill's six
  questions: does it change files; can one writer do it; are the parts
  disjoint; does one consume another's interface; is a choice worth paying for
  several times; which tier each cell needs. **One writer** is the default,
  editing the main tree with read-only cells around it. A **read-only
  fan-out** is three cells by default, about ten for broad research.
  **Parallel slices** take about three writers at most, one lane each. A
  **contract-first split** commits the interface before the lanes start. A
  **bake-off** pays every attempt in full, so two or three, preferring
  competing designs from read-only cells, with the selection rule set first.
  Each extra writer costs a worktree, an install, a review and a merge.
- A writing or QA cell works by `.agents/skills/workloop/working-practice.md`:
  how it tests, starts servers, waits and edits. `brief` prints it for a lane,
  `implementer` and `qa-verifier` carry it, and the lead pastes it into a
  generic cell's prompt.
- A generic cell is `general-purpose` with an explicit model; a named persona
  fixes model and effort in its frontmatter, so use one when effort must be
  fixed. The `reviewer` persona pins no model: the lead picks one at dispatch
  to suit the artifact.
- A generic cell keeps every tool, so constrain its handoff and hold the
  sandbox boundary; one that only reads declares it by opening its prompt with
  `READ-ONLY`, and the gate then refuses every Edit, Write, MultiEdit and
  NotebookEdit it attempts. One that reads and writes notes opens with
  `NOTES-ONLY` and may write in the product folder only, minus its risky parts
  (`.py`, `.sh`, `.js` and `.mjs` files; `tools`, `backups`,
  `node_modules` and `__pycache__` folders), where the repository's
  `config.json` sets `hooks.product_folder.enabled`; elsewhere the dispatch is
  refused. A cell never writes a `REPORT`, `SUMMARY`, `FINDINGS` or `ANALYSIS`
  `.md` file, which Claude Code refuses: it returns that content as its reply,
  and the product's own conventions name every other note file.
- Two or more concurrent writers in one checkout go through a `workloop` run;
  `parallel-writers-gate.sh` enforces it, and its denial names the commands. A
  writer that works in a separate directory, no copy of this repository, says
  so with one prompt line `WORKSPACE: <absolute path>` and may then write
  anywhere but this checkout.
- Plan mode blocks edits until the operator approves the plan, but only an
  attended terminal session offers that approval: unattended runs (`claude -p`,
  background cells) expose no plan-approval tool, and auto mode has none
  (probed 2026-10-04 on 2.1.289). The root's human gates therefore stop and
  report; plan mode is a convenience in an attended session, never the gate.

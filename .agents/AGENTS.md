---
applyTo: '.agents/**'
paths:
  - '.agents/**'
---

# Agent Scaffold Rules

## Ownership

- `.agents/` is canonical; host paths are static adapters or symlinks. Never edit through a symlink.
- Runtime ledgers (`.sources-ledger`, `.wrap-state-*`, `.wrap-edits-*`, `.wrap-commits-*`, `.compaction-pending`, `.workloop-state.json`) and the in-tree `worklog/` are gitignored state.
<!-- colloid-only -->
- `.genome-ledger` and `.mutagen-ledger` are runtime state on the same terms.
<!-- /colloid-only -->
- `config.json.example` defines hook defaults; `policy.json` is the tracked per-repository policy — a hook the repository runs without, the scripts its publish guard must ask about — and `config.json` the ignored per-operator override layered on top, read alike by `hooks/lib/config.py`. While either fails to parse, the publish guard asks on every command that could run a listed script. It reads `hooks.guard_publish.dry_run_commands` from `policy.json` only: exempting a script from an ask is a repository decision, beyond `config.json`'s reach. `hooks.product_folder.enabled` is the opposite, config-only key: opening a folder outside the repository is one operator's choice on one machine, so `product_folder.py` reads it from `config.json` alone and never from `policy.json`.
- `mcp.json` is the MCP registry and its project state. Toggle a server only through `python3 .agents/mcp.py enable|disable <name>`, which also rewrites every host's MCP configuration; commit intentional state changes.
- `.opencode/opencode.json` and `.opencode/instructions/colloid.md` are generated connection files, like `.codex/config.toml`. `mcp_opencode.py` renders the permission rules and agent roles from `.agents/claude/settings.json` and `.agents/personas`, so edit those sources and never the generated file.
- `personas/*.md`, linked from `.claude/agents/*.md`, are Claude-native definitions and `.codex/agents/*.toml` static Codex ones; model and effort are explicit in each, not generated from a tier registry.
- `check-layout.py` verifies scaffold-owned links and never creates, rewrites, or prunes operator files.

## Editing contracts

- Keep the scaffold small: add a generator only when a real artifact can be neither represented directly nor linked.
- A persona is a cached hot path, not the only legal cell; grant it only the tools, skills, MCP servers, hooks, and memory its role recurrently needs.
- Claude persona configuration belongs in YAML frontmatter; Codex leaves model and effort to invocation time, so its TOML description states the exact dispatch.
- Every skill follows Agent Skills format, with `lint-skills.sh` the authority on its enforceable limits.
- Put load-bearing skill instructions first: compaction may retain only a long skill's opening.
- A hook policy ships with a direct firing test. Prefer testing observable behavior over mutation machinery that tests the test harness.
- Hook payloads travel on stdin. Keep adapters thin and shared behavior in `hooks/policy/` or `hooks/lib/`.
- Commit repository-owned MCP bundles under `mcp-servers/*/dist/`, which clients launch before any install or build, and run each server's bundle check after source changes.
- A stack pack declares `paths:` and `detect:`, and `detect-deps:` when its stack can show only as a dependency. This repository carries every pack; an export drops `stack_packs.carrier`, and each target deletes packs its codebase does not use.

## Writing contract language

A contract line is a program the model runs, and whether a session follows it on a given turn is the model's call, however strongly it is worded (Claude Code's best-practices guide, code.claude.com/docs/en/best-practices). Write each line so that it fires, and test it by running it.

- Put wording that must fire at one step where the agent already is, at that step. A line that only points at another file did not get the file opened. Keep a pointer where one text must stay single-sourced, as the reviewer contract does because the review harness grades it, or where the file reaches the agent another way: pasted into a dispatch, loaded by a hook, or matched by a `paths:` glob.
- Ask for an artifact the next step reads, named at the workflow step that produces it, such as the Plan row's `Lenses:` block, rather than a mental act; "consider" and "apply" leave nothing to check. A report line asked for in a prose paragraph was not written, so a statement that must appear needs a hook.
- Quote a phrase the model already knows word for word, such as "carve the problem at the joints", where the phrase carries a method; two wordings of one idea drift apart.
- Ask a reviewer for every defect. Anthropic's Opus 5 prompting guide (platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5) warns that "only report high-severity issues" or "be conservative" can make it report less, and recommends filtering in a separate pass; the lead's dispositions are that pass, and no rule tells the lead to drop a category of finding.
- Order actions, not statements. "Build one command that goes red" before an edit is mostly followed; "before the first edit, write the cause" is not, because sessions write statements in the report that ends the turn. Enforce a statement's timing with a hook, or drop the timing.
- Write plainly. Capitals and emphasis words make a rule over-apply, and lines such as "keep going" or "loop until done" cause over-work (Claude Code's best-practices guide); on Opus 5, explicit re-check instructions cause over-verification (the Opus 5 guide). A vivid phrase earns its place only by carrying a method.
- Leave out what the agent would find by reading the code and would actually go and look for.
- Prefer a hook or a deny rule for a rule with zero exceptions, where one can detect the behaviour; otherwise keep the line and file the gap.
- Give every rule its exit. A line that assumes its precondition, such as "that run" when no run could be built, strands the agent when the precondition fails.
- Test a rewrite before it lands, in fresh headless sessions on the model that will read it: on Claude Code, `command claude -p "<prompt>" --model <model> --allowedTools=<tools> --output-format stream-json --verbose`, run from a fixture folder whose `CLAUDE.md` is the drafted contract; on another host, its equivalent headless run. Write the pass condition first, run at least twice, and grade from the transcript's tool order and text, not from the session's own summary. After three wordings of one line fail, stop rewording and bring the operator the choice between enforcing it with a hook and dropping the requirement; record the ruling in `decisions.md`.
<!-- colloid-only -->
- `knowledge/research/2026-11-10-contract-wording-in-fresh-sessions.md` holds the runs and quotes behind these directions; the word-for-word direction rests on the lead's judgement, not a run. `2026-11-09-expert-guideline-phrasing.md` beside it holds the outside phrasings still waiting for a rewrite.
<!-- /colloid-only -->

## Hierarchical instructions

Read the nearest `AGENTS.md` before editing a subtree. Canonical scoped files carry both `applyTo:` and `paths:` frontmatter, the keys Copilot and Claude consume; Codex and Kimi read the file as plain instructions.

| Scope | Canonical |
| --- | --- |
| Scaffold | `.agents/AGENTS.md` |
| Claude adapter | `.agents/claude/AGENTS.md` |
| Skill (optional) | `.agents/skills/<name>/AGENTS.md` |
| Path or stack rule | `.agents/rules/<name>.md` |

<!-- colloid-only -->
| Scope | Canonical |
| --- | --- |
| Demo | `demo/AGENTS.md` |
<!-- /colloid-only -->

Fan-out is by symlink:

- Copilot: `.github/instructions/*.instructions.md` to canonical files.
- Claude: layer `CLAUDE.md` to sibling `AGENTS.md`; `.claude/skills/*`, `.claude/agents/*`, and `.claude/rules/*` to `.agents/`.
- Codex: `.codex/hooks.json` and hook adapter links; persona TOMLs stay host-native because Codex does not read Claude frontmatter.

A skill's `AGENTS.md` governs editing it and its `SKILL.md` using it; a file under `rules/` governs product code its globs match.

## Verification

Run the narrow checks for the surface changed:

```sh
python3 .agents/check-layout.py
.agents/lint-skills.sh
.agents/test-lint-skills.sh
python3 .agents/lint-breadcrumbs.py
python3 .agents/lint-decisions.py
python3 .agents/check-test-isolation.py
.agents/test-session-start.sh
.agents/test-done-prime.sh
.agents/test-workloop.sh
.agents/test-provision.sh
.agents/test-worktree-provision.sh
.agents/test-worktree-sessions.sh
.agents/test-parallel-writers.sh
.agents/test-workloop-inbox.sh
.agents/test-style-inject.sh
.agents/test-ui-gate.sh
.agents/test-teardown-gate.sh
.agents/test-session-end.sh
.agents/test-post-edit-check.sh
.agents/test-stop-investigate.sh
.agents/test-provenance-gate.sh
.agents/test-review-contract.sh
python3 .agents/test-sources-matcher.py
python3 .agents/test-guard-destructive.py
python3 .agents/test-wait-gate.py
.agents/test-keychain-notice.sh
.agents/test-session-wrap.sh
python3 .agents/test-guard-publish.py
python3 .agents/test-hosted-scripts.py
.agents/test-device-policy.sh
.agents/test-mcp.sh
.agents/test-opencode.sh
python3 .agents/test-lsp.py
python3 .agents/test-browser-sync.py
.agents/test-permissions.sh
.agents/test-statusline.sh
.agents/test-hook-lookup.sh
.agents/test-product-folder.sh
.agents/test-mods.sh
.agents/test-codex.sh
# colloid-only
python3 .agents/lint-contract.py
python3 .agents/eval/test-cell-time.py
.agents/test-export.sh
.agents/test-stack-packs.sh
python3 .agents/port-public.py check
.agents/test-port-public.sh
# /colloid-only
```

<!-- colloid-only -->
Run `export-scaffold.py` only from a reviewed commit: it reads Git, not the working tree.
<!-- /colloid-only -->

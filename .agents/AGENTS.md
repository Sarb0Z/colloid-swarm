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
.agents/test-ui-gate.sh
.agents/test-teardown-gate.sh
.agents/test-post-edit-check.sh
.agents/test-stop-investigate.sh
.agents/test-provenance-gate.sh
.agents/test-review-contract.sh
python3 .agents/test-sources-matcher.py
python3 .agents/test-guard-destructive.py
python3 .agents/test-wait-gate.py
.agents/test-session-wrap.sh
python3 .agents/test-guard-publish.py
python3 .agents/test-hosted-scripts.py
.agents/test-device-policy.sh
.agents/test-mcp.sh
python3 .agents/test-browser-sync.py
.agents/test-permissions.sh
.agents/test-statusline.sh
.agents/test-hook-lookup.sh
.agents/test-product-folder.sh
.agents/test-mods.sh
.agents/test-codex.sh
# colloid-only
python3 .agents/lint-contract.py
.agents/test-export.sh
.agents/test-stack-packs.sh
python3 .agents/port-public.py check
.agents/test-port-public.sh
# /colloid-only
```

<!-- colloid-only -->
Run `export-scaffold.py` only from a reviewed commit: it reads Git, not the working tree.
<!-- /colloid-only -->

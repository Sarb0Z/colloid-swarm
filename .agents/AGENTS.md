---
applyTo: '.agents/**'
paths:
  - '.agents/**'
---

# Agent Scaffold Rules

## Ownership

- `.agents/` is canonical; a host path is a static adapter or a symlink to it. Never edit through a symlink: an editor that saves by rename replaces the link with a plain file, and from that save on the host reads a copy the scaffold no longer owns, in silence, until `check-layout.py` runs.
- Runtime ledgers (`.sources-ledger`, `.wrap-state-*`, `.compaction-pending`, `.workloop-state.json`) are gitignored state: the hooks and the workloop controller rewrite them as sessions run, and tracked they would dirty every diff and carry one machine's session into every clone.
<!-- colloid-only -->
- `.genome-ledger` and `.mutagen-ledger` are runtime state on the same terms.
<!-- /colloid-only -->
- `config.json.example` defines the hook defaults. `policy.json` is the tracked per-repository policy — a hook the repository runs without, the scripts its publish guard must ask about — and `config.json` the ignored per-operator override layered over it; the two share one shape, and `hooks/lib/config.py` reads both. While either fails to parse, the publish guard asks on every command that could run a listed script: a guard that cannot read its policy cannot know which scripts it exempts, so it fails closed. It reads `hooks.guard_publish.dry_run_commands` from `policy.json` alone: an exemption from an ask is a repository decision, which `config.json` cannot declare.
- `mcp.json` is the MCP registry and holds its project state. Toggle a server through `python3 .agents/mcp.py enable|disable <name>`, which validates the registry and rebuilds every host's MCP configuration in the same step — a hand edit leaves those configurations stale until the next sync. Edit the file by hand only for what that command cannot express, and commit intentional state changes.
- `personas/*.md` are the Claude-native definitions, linked from `.claude/agents/*.md`; `.codex/agents/*.toml` are the static Codex definitions. Each states its model and effort outright; no tier registry generates them.
- `check-layout.py` verifies the links the scaffold owns; it never creates, rewrites, or prunes an operator's files, because it ships to every satellite, where the files beside the links are not the scaffold's to touch.

## Editing contracts

- Keep the scaffold small. Add a generator only when a real artifact can be neither represented directly nor linked: a generated file is a second copy of its source, and a second copy drifts from the first the day someone forgets to regenerate it.
- A persona is a cached hot path, not the only legal cell. Give it only the tools, skills, MCP servers, hooks, and memory its role repeatedly needs; anything more is context every dispatch pays for and a capability the cell can misuse.
- A Claude persona's configuration belongs in its YAML frontmatter. Codex model and effort remain invocation-time controls; its TOML description states the exact dispatch.
- Every skill follows the Agent Skills format; `lint-skills.sh` is the authority on its enforceable limits.
- Put load-bearing skill instructions first: compaction may retain only the beginning of a long skill, and what it drops it drops without a trace, so a rule on line 300 of a skill binds only until the first compaction.
- A hook policy ships with a direct firing test — the test feeds the hook its event and asserts that it fired — because a hook that does not fire fails exactly like a hook that was never written, with no error anywhere. Prefer testing observable behavior over mutation machinery that tests the test harness: the first proves the hook, the second proves only that the mocks agree with each other.
- Hook payloads travel on stdin. Keep adapters thin and shared behavior in `hooks/policy/` or `hooks/lib/`: each host runs its own adapter, and logic that lives in one adapter is a policy only that host enforces.
- Repository-owned MCP bundles under `mcp-servers/*/dist/` are committed, because clients launch them before any install or build. Run each server's bundle check after a change to its source.
- A stack pack declares both `paths:` and `detect:`. This repository carries every pack; an export drops `stack_packs.carrier`, and each target deletes the packs its codebase does not use.

## Hierarchical instructions

Read the nearest `AGENTS.md` before editing a subtree. A canonical scoped file carries both `applyTo:` and `paths:` frontmatter: Copilot and Claude consume those keys, and Codex and Kimi read the file as ordinary instructions.

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
| trial-co trial | `trial-project/AGENTS.md` |
<!-- /colloid-only -->

Fan-out is by symlink:

- Copilot: `.github/instructions/*.instructions.md` link to the canonical files.
- Claude: each layer's `CLAUDE.md` links to its sibling `AGENTS.md`, and `.claude/skills/*`, `.claude/agents/*`, and `.claude/rules/*` link into `.agents/`.
- Codex: `.codex/hooks.json` and the hook adapter links; the persona TOMLs stay host-native, because Codex does not read Claude frontmatter.

A skill's `AGENTS.md` governs editing the skill and its `SKILL.md` governs using it; a file under `rules/` governs the product code its globs match.

## Verification

Run the narrow checks for the surface a change touches:

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
.agents/test-mods.sh
.agents/test-codex.sh
# colloid-only
python3 .agents/lint-contract.py
.agents/test-export.sh
.agents/test-stack-packs.sh
# /colloid-only
```

<!-- colloid-only -->
Use `export-scaffold.py` only from a reviewed commit: it reads Git, not the working tree, so the kit carries exactly what was committed — an uncommitted fix is absent from it, and an unreviewed commit reaches every satellite unreviewed.
<!-- /colloid-only -->

# Transplant guide

The kit is a reviewed snapshot, not an installer. Merge it into the target's
current branch after inspecting that repository's stack, existing instructions,
dirty state, host configuration, and tracked symlinks.

## Preserve first

Back up or inventory existing `AGENTS.md`, `CLAUDE.md`, `.agents/`, `.claude/`,
`.codex/`, `.kimi/`, `.kimi-code/`, `.mcp.json`, and Copilot instruction paths.
Do not overwrite untracked operator state. Keep unrelated host features such as
commands, plugins, output styles, or project-specific agent definitions.

## Adapt the kit

1. Merge the target's real codebase rules into root and scoped `AGENTS.md`
   files. Generic scaffold rules do not replace framework, architecture, or
   product invariants.
2. Delete every `stack-*.md` whose `detect:` markers the target does not have.
   Keep all stacks it genuinely runs, including multiple stacks in a monorepo.
3. Delete skills the target cannot use. Preserve specialized target skills and
   their existing host links.
4. Keep repository-owned MCP bundles only when their tools make sense. If a
   bundle is removed, run `export/drop-server.py <repo> <name>` so the registry
   does not point at a missing executable.
5. Set `.agents/mcp.json` to the target's requested project defaults. The base
   posture is `context7`, `playwright`, and `research-mcp` on; everything else
   off.
6. Keep `.kimi/` only when the target uses Kimi. Preserve existing CI and adapt
   its checks rather than copying this repository's workflow blindly.
7. Merge `export/debt-log-entry.md` into the target's debt log when it contains
   entries, then remove the `export/` directory.

## Materialize host state

The kit already carries static Claude/Codex/Copilot links and persona files.
After merging:

```sh
python3 .agents/check-layout.py
python3 .agents/mcp.py
```

Inspect `.agents/codex/hooks.json`, then establish project and hook trust:

```sh
python3 .agents/codex/trust-hooks.py "$(pwd)"
```

Run trust one repository at a time because it updates the user's Codex config.
Start a new Claude/Codex/Kimi session after MCP state changes.

## Verify in the target

```sh
python3 .agents/check-layout.py
.agents/lint-skills.sh
python3 .agents/check-stack-packs.py
.agents/test-session-start.sh
python3 .agents/test-guard-destructive.py
python3 .agents/test-guard-publish.py
.agents/test-mcp.sh
.agents/test-codex.sh
```

Then run the target's own focused checks. Drive one deployed hook through its
host adapter and verify the host sees the intended personas and project MCP
records. A parsed file proves syntax; it does not prove host discovery.

Review `git status --porcelain --untracked-files=all` before staging. Stage only
the intended scaffold and target-instruction paths.

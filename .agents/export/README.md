# Transplant guide

The kit is a reviewed snapshot, not an installer. Merge it into the target's
current branch after inspecting that repository's stack, existing instructions,
dirty state, host configuration, and tracked symlinks.

## Preserve first

Back up or inventory existing `AGENTS.md`, `CLAUDE.md`, `.agents/`, `.claude/`,
`.codex/`, `.kimi/`, `.kimi-code/`, `.mcp.json`, and Copilot instruction paths.
Do not overwrite untracked operator state. Keep unrelated host features such as
commands, plugins, output styles, or project-specific agent definitions.

## Build the kit from a commit

`export-scaffold.py` reads `git archive HEAD`, so an uncommitted scaffold fix
does not travel. It prints a warning and still exits 0, and the kit silently
ships the old file. Commit first.

Satellites vendor their own copies of the scaffold and drift behind at
different rates. Propagating one hook or feature is an adaptation against the
target's current copy, never a `cp` from this repository.

Moving a satellite's directory is its own procedure: every host keys session
history by absolute path. Follow `.agents/playbooks/move-project-directory.md`.

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
   entries. The kit drops `.agents/breadcrumbs.md`, `.agents/debt-log.md`, and
   `.agents/decisions.md`, so the target's copies are a create, not a merge.
8. The export does not strip prose about what you pruned. After dropping a
   server or skill, grep the kit for its name: `.agents/README.md` makes
   inventory claims, and a dropped skill can be named inside a kept skill's
   frontmatter `description`.
9. Merge `export/gitignore-fragment` by appending, before the first sync. An
   unanchored `dist/` already in the target also matches
   `.agents/mcp-servers/*/dist/`; the negation only works after it. Verify
   with plain `git check-ignore`, not `-v`.
10. A disabled registry entry masks a same-named user-level server in Codex
    only. `sync-mcp.sh` omits disabled servers from `.mcp.json` entirely, so
    Claude still loads the user-level one.
11. Remove the `export/` directory last; steps 7 through 9 read from it.

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

Drive the deployed post-edit adapter with a file carrying a real error per
language, using a violation the tool will not auto-fix: `ruff check --fix`
repairs an unused import before the reporting pass, so that reads as success.
A gate that ran nothing and a gate that passed look identical from exit 0.

Review `git status --porcelain --untracked-files=all` before staging. Stage only
the intended scaffold and target-instruction paths; never `git add -A` in a
repository that may hold in-flight work.

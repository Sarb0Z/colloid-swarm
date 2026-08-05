# Transplanting the scaffold into a satellite

Satellite repositories vendor their own copy of this scaffold. They never
symlink across repositories, and none of them carries the genome layer.
`.agents/export-scaffold.py` emits the copy they receive.

```sh
.agents/export-scaffold.py /tmp/kit      # writes .agents/ + .kimi/ + export/
```

The export is a subtraction of this repository, not a rewrite of it. It drops
the genome subsystem, drops every hook entry that names a dropped policy, drops
the config keys that describe one, and strips regions the source marks
`colloid-only`. Read the module docstring for why it may not do anything else.

## What the target repository decides

The export is uniform. These four choices are per repository.

- **Skills.** Install what the repository can use and delete the rest. A React
  Native application has no use for `mobile-responsive-web`; an API serves no
  pages, so it needs neither that nor `seo-geo-growth-audit`.
- **Repository-owned MCP servers.** `research-mcp` suits every repository.
  `security-mcp` needs an authorized live HTTP target, so it belongs only where
  one exists. To omit a server, delete `.agents/mcp-servers/<name>/` **and** run
  `export/drop-server.py <repo> <name>`. Both halves are required:
  `mcp_registry.resolve_registry` validates the local paths of every registry
  entry before any enabled or disabled filter runs, so a registry entry whose
  bundle is absent makes every sync script exit non-zero.
- **MCP servers that need a surface the repository lacks.** `appium-mcp` drives a
  mobile app on a device or simulator, so it is ~31 tools of schema for nothing
  in a repository with no native app. Disable it there rather than removing the
  registry entry: a disabled entry still masks a same-named user-level server,
  which is what the off-state is for. Set the flag in `config.json.example` as
  well as `config.json` wherever `config.json` is gitignored — the tracked
  example is then the only place a fresh clone reads a toggle from.
- **Engines.** Install `.kimi/` only where Kimi is wired. `sync-mcp.sh` writes
  Kimi's project file only when `.kimi/` or `.kimi-code/` exists, so a
  repository with neither gets no Kimi output and needs no further pruning.
  Codex needs nothing beyond running the sync.
- **`.gitignore`.** Merge `export/gitignore-fragment` **before** the first sync
  run. The sync writes `.kimi-code/mcp.json` at mode 0600 with environment
  variables already expanded, and every generated file left untracked and
  unignored also makes `session-wrap.sh` read the tree as dirty on every Stop
  hook.

  Watch for an unanchored `dist/` or `package-lock.json` rule already in the
  repository. Either one also matches inside `.agents/mcp-servers/`, which drops
  the bundle the registry points at: the repository looks fine locally and a
  fresh clone fails `resolve_registry`, so every sync script exits non-zero. The
  fragment ends with the re-includes that repair it. Confirm with plain
  `git check-ignore .agents/mcp-servers/research-mcp/dist/server.js` — not the
  `-v` form, which prints the matching `!` rule while still exiting non-zero, so
  it reads as "ignored" for a path that is not. The definitive check is that the
  bundle appears in `git diff --cached --name-only` before you commit.

## Order that matters

1. Back up every dirty or untracked scaffold file first. The sync scripts unlink
   and re-link their targets, so an uncommitted change under `.agents/`,
   `.claude/`, `.codex/` or `.mcp.json` is lost with no way back.
2. Merge the `.gitignore` fragment.
3. Merge `export/debt-log-entry.md` into the repository's `.agents/debt-log.md`.
   `session-wrap.sh` carries an inline `debt: wrap-01-concurrent-attribution`
   pointer, and a pointer with no entry is a dangling reference.
4. Run `.agents/sync-claude-agents.sh`. It chains `sync-mcp.sh`, which chains
   `sync-codex.sh --no-trust`.
5. Run `.agents/sync-codex.sh` on its own, once, **one repository at a time**.
   Only the bare form reaches `trust-hooks.py`, which read-modify-writes the
   global `~/.codex/config.toml` with no lock. Concurrent runs lose updates and
   leave an unpredictable subset of repositories with silently disarmed hooks.

## Committing

Stage scaffold paths explicitly, never `-A`, and untrack whatever the new ignore
rules turn into generated output. Then commit with **no pathspec**:
`git commit -- <paths>` is a partial commit that takes the working-tree state of
those paths and ignores the index, so every `git rm --cached` silently reverts
and the file lands in the commit again. Read `git status --porcelain` first and
confirm nothing outside the scaffold is staged — that check is what makes a
pathspec-free commit safe.

## Proving it works

Run the scaffold's own suites in the target: `lint-skills.sh`,
`test-session-start.sh`, `test-mcp.sh`, `test-codex.sh`. Then drive the
**deployed** adapter rather than a policy directly, and confirm the typecheck
gate is alive by feeding it a scratch file with a deliberate type error and
checking for exit 2. Name that file without a leading dot: TypeScript's
`include` globs skip dot-prefixed filenames, so a `.probe.ts` is never checked
and a dead gate reads as a passing one.

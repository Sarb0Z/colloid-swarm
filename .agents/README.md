# `.agents/` — tool-neutral agent scaffold

Single source of truth for agent configuration, shared across coding tools.
Each tool's own directory holds only a thin **symlink** (when the tool reads
the same format from a fixed path) or **adapter** (when it needs a different
format or location) pointing back here. Edit things here, once.

## Layout & how each tool sees it

| Canonical (here) | What | Claude Code | Kimi CLI |
|---|---|---|---|
| `../AGENTS.md` | Agent instructions | `CLAUDE.md` → symlink | native (reads `AGENTS.md`) |
| `skills/<name>/` | Reusable skills (`SKILL.md`) | `.claude/skills/<name>` → symlink | native (auto-discovers `.agents/skills/`) |
| `mcp.json` | MCP servers (`mcpServers` JSON) | `.mcp.json` → symlink | `kimi --mcp-config-file .agents/mcp.json` |
| `hooks/policy/*.sh` | Engine-agnostic hook policies | `.claude/settings.json` + adapter | `.kimi/config.toml` + adapter |
| `genome.sh` | Genome emitter (parses `../genomes.md`) | called by the orchestrator; `genome-guard.sh` enforces | called by the orchestrator (native) |
| `mutagen.sh` + `mutagen.md` | Mutagen: roll a vector + blind-rewriter contract | called by the orchestrator (`panspermia-mutation` skill) | called by the orchestrator (native) |
| `config.json` | Scaffold toggles, thresholds, model routing | read by every hook + `sync-claude-agents.sh` | read by wired hooks |
| `researcher.md` | Researcher-cell contract (search ladder + cited evidence) | `.claude/agents/researcher.md` → native agent (`model: sonnet`); `sources-capture` logs its web calls | stamped + dispatched (native; no capture) |
| `breadcrumbs.md` | Deferred non-blocking *work* (a queue) | surfaced by the SessionStart hook | — |
| `debt-log.md` | Standing tradeoffs & deferred *decisions*, `debt: <id>` refs from code | committed; pulled on demand, not auto-surfaced | — |
| `AGENTS.md` (here + `../demo/`, `../tensium-trial/`, `../.claude/`, `skills/<name>/`) | Scoped instructions with dual `applyTo`/`paths` frontmatter | `.claude/rules/<skill>.md` + sibling `CLAUDE.md` → symlinks | native (root `AGENTS.md` points to subtree files) |

`genome.sh` writes a transient `.genome-ledger` (recent draws, for anti-repeat);
`mutagen.sh` writes `.mutagen-ledger` (each roll, read back for operator
disclosure); the `sources-capture` hook writes `.sources-ledger` (every web
lookup, the evidence trail). All, with `.compaction-pending`, are gitignored at
the repo root.

(`.github/copilot-instructions.md` also symlinks to `../AGENTS.md`.)

## Symlink vs adapter

- **Symlink** when the tool reads the *same content* from a fixed path
  (instructions, skills, MCP JSON). One canonical file; the tool's path
  resolves through the link. That's why `CLAUDE.md`, `.mcp.json`, and each
  `.claude/skills/<name>` are symlinks, not copies.
- **Adapter** when formats or event contracts differ. Hooks stay adapters:
  Claude and Kimi use different event names and stdin shapes, so a small
  per-tool script normalizes them into the shared policy contract. Never
  symlink `.claude/settings.json` / `.kimi/config.toml`. See
  `.claude/hooks/README.md`.

## Configuration

One file, `.agents/config.json`, controls the whole scaffold:

- **Hook toggles** — enable/disable any of the 9 policies without touching
  `.claude/settings.json` or `.kimi/config.toml`.
- **Thresholds** — `session_wrap.trivial_files/lines/heavy_lines` (env vars still
  override).
- **Model routing** — `models.researcher` (etc.) drives `.agents/sync-claude-agents.sh`,
  which regenerates `.claude/agents/*.md` with the correct `model:` frontmatter.
- **Swarm behavior** — `swarm.genome_stamping`, `swarm.exempt_subagent_types`,
  `swarm.default_register`.

`config.json.example` is the committed template — every knob present and on.
The real `config.json` is **gitignored and per-repo**: copy the example, tune it
to this repo, and keep the tuning local (no fleet-wide merge conflicts). Missing
config = all defaults enabled, matching the example; a broken config is never
fatal — hooks fail open.

```sh
cp .agents/config.json.example .agents/config.json   # then tune
```

```sh
# After editing config.json, regenerate Claude agent definitions
.agents/sync-claude-agents.sh
```

## Adding things

- **A skill** — drop `skills/<name>/` here, then wire Claude:
  ```sh
  for d in .agents/skills/*/; do n=$(basename "$d"); ln -snf "../../.agents/skills/$n" ".claude/skills/$n"; done
  ```
  Per-leaf symlinks (a whole-dir `.claude/skills` symlink works but is
  version-fragile). Kimi picks it up natively.
  Give the skill a scoped `skills/<name>/AGENTS.md` (see the skeleton in
  `.github/instructions/README.md`), then add its fan-out:
  `.claude/rules/<name>.md` and `.github/instructions/00-<name>.instructions.md`,
  both symlinks to the canonical file.
- **A scoped instruction file** — follow the scope contract in
  `.github/instructions/README.md`: canonical `AGENTS.md` co-located with the
  subtree, dual `applyTo`/`paths` frontmatter, symlink fan-out per tool.
- **An MCP server** — edit `mcp.json`. Claude gets it through the `.mcp.json`
  symlink; Kimi through the `--mcp-config-file` flag above.
- **A new tool** — add its directory with a symlink (same format) or adapter
  (different format). Don't scaffold tools nobody uses.

## Caveat

Symlinks need `core.symlinks=true` (the default on macOS/Linux). A Windows
checkout without it materializes them as text files containing the path —
use a generated-copy step there instead.

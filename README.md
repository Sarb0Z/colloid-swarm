# Colloid Swarm

An engine-agnostic agent scaffold: one canonical instruction tree, one set of
enforcement hooks, and one MCP registry, fanned out to Claude Code, Codex, Kimi,
and GitHub Copilot. Drop it into a repository and the four engines read the same
rules and run the same guards.

The scaffold is the portable part. This repository also carries a creative layer
— operating registers and personality genomes — that no other repository
receives. The two layers are separable by design, and the export tool performs
the separation.

## Requirements

| Component | Needs |
| --- | --- |
| Hooks, sync scripts, demo | `bash`, `python3` (standard library only) |
| `research-mcp`, `security-mcp` | Node.js `>=20.19.0` |
| Everything else | nothing — the instruction tree is Markdown and symlinks |

## Install into your repository

```sh
git clone https://github.com/Sarb0Z/colloid-swarm.git
cd colloid-swarm
.agents/export-scaffold.py /tmp/kit      # target must be empty or absent
```

The export refuses a non-empty target, so it cannot write straight into an
existing repository. Emit the kit to a fresh directory, review it, then copy
`.agents/`, `.kimi/`, and `AGENTS.md` into your repository.

The export writes `.agents/`, `.kimi/`, `AGENTS.md`, and `export/`, and works by
subtraction: it drops the genome subsystem, drops each hook entry that names a
dropped policy, drops the config keys that describe one, and strips regions
marked `colloid-only`. It never rewrites prose, so it cannot silently corrupt
reworded canon.

The export copies files **as tracked by git**. A dirty working tree, a local
`.agents/config.json`, the runtime ledgers, and `browser-extensions/` never
travel.

Read `.agents/export/README.md` for the transplant method and the four choices
each target repository must make.

## Layout

### The instruction tree

`AGENTS.md` at the repository root is the operating contract: principles in
priority order, the research → plan → hostile-review → implement → hostile-review
workflow, behavioral rules, and the delegation policy.

Scoped `AGENTS.md` files sit next to the code they govern, so an engine loads a
module's rules only when it works in that module. This repository holds 19
canonical files and 82 fan-out symlinks. Canonical files carry dual
`applyTo:` (Copilot) and `paths:` (Claude Code) YAML frontmatter; other engines
read the file as plain Markdown and ignore the frontmatter.

Always edit the canonical file. The symlinks are generated fan-out:

- `CLAUDE.md` → sibling `AGENTS.md`
- `.claude/rules/<skill>.md` → the skill's canonical `AGENTS.md`
- `.github/instructions/*.instructions.md` → canonical files

Authoring rules live in `.github/instructions/README.md`.

### Enforcement hooks

Nine policy scripts in `.agents/hooks/policy/`, engine-agnostic and written
against a normalized payload:

| Policy | Purpose |
| --- | --- |
| `guard-destructive.sh` | Blocks irreversible commands — broad `rm -rf`, force-push, `reset --hard`, production mutation over SSH, destructive DDL, unrestricted `DELETE`/`UPDATE` |
| `genome-guard.sh` | Requires a genome stamp on a subagent dispatch (this repository only) |
| `sources-capture.sh` | Records sources a session cited |
| `research-prime.sh` | Primes research behavior on prompt submit |
| `post-edit-check.sh` | Runs scoped checks after an edit |
| `session-start.sh` | Surfaces breadcrumbs and MCP state at session start |
| `session-wrap.sh` | Wraps up session state |
| `stop-investigate.sh` | Inspects the stop payload's last assistant message |
| `pre-compact.sh` | Restates policy that a compaction would drop |

Each engine supplies a thin adapter that normalizes its own hook I/O into these
scripts:

```
settings.json → adapter.sh [--agent <sel>] <policy>.sh → .agents/hooks/policy/
```

The adapter resolves the repository root relative to its own location, so the
scaffold works wherever you drop it. Codex hook commands are the exception: they
resolve the Git root from the working directory first, so they find no adapter
from a submodule or an unrelated repository.

### Skills

Fourteen skills in `.agents/skills/`, each with a `SKILL.md` (how to use it) and
a scoped `AGENTS.md` (how to edit it):

- **Security** — `security-audit` (source-only review), `dynamic-security-scan`
  (authorized live target), `security-scan` (commit-time secret and dependency
  gate), `pentesting` (adversarial red-team method)
- **Quality** — `thermo-nuclear-code-quality-review`, `scalability-audit`,
  `perf-budget`
- **Frontend** — `frontend-design`, `mobile-responsive-web`,
  `react-native-expert`, `seo-geo-growth-audit`
- **Research** — `search-and-cite`, `market-researcher`
- **Dispatch** — `panspermia-mutation` (this repository's genome layer)

Install what your repository can use and delete the rest. An API serves no pages,
so it needs neither `mobile-responsive-web` nor `seo-geo-growth-audit`.

`.agents/lint-skills.sh` validates skill format.

### MCP registry

`.agents/mcp.json` is the single source of truth for ten servers. Toggle each per
repository in `.agents/config.json` (`mcp.servers.<name>.enabled`), or use the
subcommand, which flips the toggle and regenerates in one step:

```sh
.agents/sync-mcp.sh enable  research-mcp
.agents/sync-mcp.sh disable exa
```

`sync-mcp.sh` generates every file a tool actually consumes: `.mcp.json`,
`.kimi-code/mcp.json`, `.codex/config.toml` (through `sync-codex.sh`), the
`enabledMcpjsonServers` key in `.claude/settings.local.json`, and the
`.github/lsp.json` LSP fan-out. The generated files are gitignored; the registry
and the toggles are not.

MCP servers connect at session start, so restart the session after a toggle.

A server may also carry `codex_enabled: false`, which keeps it out of the Codex
config while it stays on elsewhere. `atlassian` and `exa` use this, because Codex
accepts only stdio or streamable HTTP.

| Server | Transport | Default |
| --- | --- | --- |
| `context7` | stdio | on |
| `playwright` | stdio | on |
| `playwright-reader` | stdio | off — needs `.agents/fetch-extension.sh ublock-lite` |
| `appium-mcp` | stdio | on — needs `ANDROID_HOME` for Android targets |
| `research-mcp` | stdio | on — repository-owned |
| `security-mcp` | stdio | off — repository-owned; needs an authorized target |
| `linear` | HTTP | on — OAuth on first use |
| `atlassian` | SSE | on — OAuth on first use |
| `greptile` | HTTP | off — needs `GREPTILE_API_KEY` |
| `exa` | HTTP | off — needs `EXA_API_KEY` |

Two servers are repository-owned and ship their source in
`.agents/mcp-servers/`:

- **`research-mcp`** — article and PDF extraction (`fetch_readable`) and
  open-access resolution (`resolve_open_access`). Set
  `RESEARCH_MCP_CONTACT_EMAIL` to enable the Unpaywall path.
- **`security-mcp`** — authorized security scanning, three tools.

`.agents/lsp.json` is the LSP registry, fanned out to `.github/lsp.json` for
Copilot CLI. Claude Code uses its own LSP plugins; Kimi has no LSP support.

### Personas and playbooks

- `.agents/personas/` — dispatchable cell definitions: `researcher.md` (an
  escalation ladder from search to fetch to `context7` to browser, with
  cross-checked and cited evidence) and `learning-reporter.md`.
- `.agents/playbooks/` — reusable procedures a session loads on demand:
  `hostile-review.md`, `review-axes.md`, `diff-wrap.md`, and the report formats
  for investigations and implementations.
- `.agents/memory/README.md` — the memory protocol. Project memories are not
  included.

### Deferred-work files

Two files split by lifecycle, and the split is load-bearing:

- `.agents/breadcrumbs.md` — deferred *work*, a queue. One line each, re-surfaced
  by `session-start.sh`. Act on the line, or delete it.
- `.agents/debt-log.md` — standing tradeoffs and deferred *decisions*. Each entry
  is a `### <id>` heading with the condition, the trigger that would justify a
  fix, and the rework cost. Code references it as `debt: <id>`.

## Engine support

| | Claude Code | Codex | Kimi | Copilot |
| --- | --- | --- | --- | --- |
| Instructions | `CLAUDE.md` → `AGENTS.md` | `AGENTS.md` | `AGENTS.md` | `.github/instructions/` |
| Hooks | 6 events | `.codex/hooks.json` | `.kimi/hooks/` | — |
| MCP | `.mcp.json` | `.codex/config.toml` | `.kimi-code/mcp.json` | — |
| LSP | own plugins | — | — | `.github/lsp.json` |
| Subagents | `.claude/agents/` | `.codex/agents/` | — | — |

Claude Code wires `PreToolUse`, `PostToolUse`, `Stop`, `SessionStart`,
`UserPromptSubmit`, and `PreCompact`.

## Tests

```sh
.agents/test-mcp.sh            # MCP registry and generated connection files
.agents/test-codex.sh          # Codex config generation and loader behavior
.agents/test-export.sh         # scaffold export correctness
.agents/test-session-start.sh  # session-start hook output
.agents/lint-skills.sh         # skill format
```

Each repository-owned MCP server also has `npm run check`. No CI workflow runs
these yet; run them by hand.

## The genome layer

This layer stays in this repository. The export removes it.

- `colloid-constitution.md` — the base operating register.
- `genomes.md` — a conserved strand plus eight genomes. `.agents/genome.sh`
  parses it and stamps one personality per subagent dispatch by sortition;
  `genome-guard.sh` enforces the stamp. The script fails closed on a malformed
  strand.
- `panspermia.txt` — an exploration register. Its active arm is the mutagen:
  `.agents/mutagen.sh` rolls a mutation vector that rewrites a task before
  dispatch, so a fan-out explores the framing space and selects the fittest.
  Driven by the `panspermia-mutation` skill.

```sh
bash demo/demo.sh
```

The demo prints live output from six beats: the genome emitter, the mutagen,
`guard-destructive.sh`, the disclosure fan-out, the scaffold export and its
subtraction assertions, and a real MCP handshake against both repository-owned
servers. It runs offline. Beat 6 needs Node and prints a SKIP notice without it.
See `demo/README.md`.

## The invariant

One rule is conserved across every register, genome, and hook: safety, law, and
consent; no destructive shortcuts; read-only production inspection; honest
hand-back. `guard-destructive.sh` is the mechanical floor. The rest is judgment.

## What this repository does not carry

Secrets and operator knowledge stay out by design: `.env*`, `settings.local.json`,
the local `.agents/config.json`, project memories, and the runtime ledgers. Copy
`.agents/config.json.example` and tune it locally.

## License

Not yet licensed. No license file means default copyright — all rights reserved
— so this code is not yet open for reuse. A license decision is pending.

`.agents/playbooks/learning-output-style.md` is adapted from an Apache-2.0 source;
see `.agents/playbooks/learning-output-style.NOTICE.md` and
`.agents/licenses/learning-output-style-APACHE-2.0.txt`.

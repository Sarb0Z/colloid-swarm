# Colloid Swarm — a portable agent operating system

Creative operating-registers + personality genomes for coding subagents, plus
the full engine-agnostic scaffold (hooks, skills, MCP, adapters, system prompt)
extracted from a working project and generalized. Aesthetic:
intelligence-as-broth, nanoswarm, panspermia.

## Registers & genomes (the creative layer)
- `colloid-constitution.md` — base operating register.
- `genomes.md` — conserved strand + 8 genomes; `.agents/genome.sh` stamps one
  per subagent by sortition, enforced by `genome-guard.sh`.
- `panspermia.txt` — cosmic exploration register (`genome.sh --register
  panspermia`); its active arm is the mutagen — `.agents/mutagen.sh` +
  `.agents/mutagen.md` rewrite a task before dispatch so a fan-out explores the
  framing space and selects the fittest (the `panspermia-mutation` skill).

## Scaffold (the mechanical layer)
- `AGENTS.md` — the operating contract (`CLAUDE.md` symlinks to it). Generic;
  codebase-specific instructions removed.
- `.agents/` — canonical store:
  - `genome.sh` — the genome emitter (parses `genomes.md`; engine-neutral).
  - `mutagen.sh` + `mutagen.md` — the mutagen: rolls a mutation vector and
    emits a blind-rewriter prompt (panspermia's active arm; engine-neutral).
  - `researcher.md` — a genome-stampable researcher cell: escalation ladder
    (WebSearch → WebFetch → context7 → playwright), cross-check, cited evidence.
  - `hooks/policy/` — engine-agnostic enforcement: `guard-destructive`,
    `genome-guard`, `sources-capture`, `research-prime`, `post-edit-check`,
    `session-start`, `session-wrap`, `stop-investigate`.
  - `skills/` — 8 reusable skills.
  - `mcp.json` — context7 + playwright.
  - `memory/README.md` — the memory protocol (project memories NOT included).
- `.claude/`, `.kimi/` — per-engine adapters that normalize hook I/O into the
  shared policy scripts. Structure-relative; no hardcoded paths.
- `CLAUDE.md → AGENTS.md`, `.mcp.json → .agents/mcp.json` — per-tool symlinks.

## How the enforcement wires up
`settings.json` → `adapter.sh [--agent <sel>] <policy>.sh` →
`.agents/hooks/policy/`. The adapter resolves the repo root relative to its own
location, so the kit works wherever you drop it as long as the
`.agents` / `.claude` / `.kimi` structure stays intact.

## The invariant
The membrane is conserved across every register, genome, and hook: safety,
law, consent; no destructive shortcuts; read-only prod inspection; honest
hand-back. `guard-destructive.sh` is the mechanical floor; the rest is
judgment. It rides with the kit — the spore coat, not optional ballast.

## Left behind on purpose (project-specific / sensitive)
Project memories, `breadcrumbs.md`, `settings.local.json`, the prod-access
specifics of `AGENTS.md`, and all secrets (`.env*`, `ssh_config`). A portable
kit carries the framework — never the operator's keys or knowledge.

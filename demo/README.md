# Scaffold demo

One command, live output, no slides:

```
bash demo/demo.sh
```

It exercises the runnable cores of the mechanical layer against real inputs and
prints what they actually emit. Every beat runs offline.

## The beats

1. **Genome emitter** (`.agents/genome.sh`) — stamps one of 8 personalities on
   a subagent dispatch. `--check` validates `genomes.md`; `--seed` pins a
   reproducible draw; `--count 5` returns guaranteed-distinct stamps for a
   parallel fan-out. `genomes.md` is the single source of truth — the script
   parses it and fails closed on a malformed strand.
2. **Mutagen** (`.agents/mutagen.sh`) — rolls a mutation vector that rewrites a
   task's framing before a blind fan-out, so the swarm explores the framing
   space and selection keeps the fittest. The eval-cost dial picks the pool:
   `--cost cheap` → a BOLD axis, `--cost expensive` → a GENTLE one.
3. **The membrane** (`.agents/hooks/policy/guard-destructive.sh`) — the
   fail-closed floor. Six destructive commands get blocked (exit 2 + reason);
   two safe ones pass. Same script both engines' adapters call.
4. **Progressive disclosure** (scoped `AGENTS.md` hierarchy) — counts the
   canonical instruction files, verifies every fan-out symlink
   (`.claude/rules/`, `.github/instructions/`, sibling `CLAUDE.md`) resolves,
   and shows one rule reached through three tool doors.
5. **Scaffold export** (`.agents/export-scaffold.py`) — emits the satellite copy
   into a temporary directory, then proves the subtraction held: every dropped
   path is absent, no engine's hook table still names a dropped policy, no
   `colloid-only` marker line survives, and the genome config keys are gone. The
   assertions read the export's own drop lists, so a new entry is checked here
   the moment it is added.
6. **Repository-owned MCP** (`.agents/mcp-servers/`) — speaks the real MCP
   handshake to both committed bundles over stdio, lists the tools each
   registers, then calls the two guards. `security-mcp` allows loopback and
   refuses a public host and a cloud-metadata address; `research-mcp` refuses
   link-local, loopback, and `file://`. Both refuse before opening a socket,
   which is why this beat needs no network.

## The "it's real" moment

The live session's own guard is wired to this same script. Writing `rm -rf ~`
straight into a shell here gets **blocked before it runs** — the demo assembles
its probe payloads at runtime specifically so presenting it doesn't trip the
very membrane it's demonstrating. The scaffold governs the session showing it.

## Requirements

`bash` and `python3` cover beats 1-5. Beat 6 also needs Node `>=20.19.0` to run
the MCP bundles; without it that beat prints a SKIP notice and the rest still
runs.

## What isn't in this script

The genome *content* (`genomes.md`, `colloid-constitution.md`, `panspermia.txt`),
the skills (`.agents/skills/`), and the per-engine adapters
(`.claude/`, `.kimi/`) are the rest of the kit — read `README.md` at the repo
root for the full map. This demo is the mechanical proof; those are the payload.

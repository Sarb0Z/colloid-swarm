# Scaffold demo

One command, live output, no slides:

```
bash demo/demo.sh
```

It exercises the three runnable cores of the mechanical layer against real
inputs and prints what they actually emit.

## The three beats

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

## The "it's real" moment

The live session's own guard is wired to this same script. Writing `rm -rf ~`
straight into a shell here gets **blocked before it runs** — the demo assembles
its probe payloads at runtime specifically so presenting it doesn't trip the
very membrane it's demonstrating. The scaffold governs the session showing it.

## What isn't in this script

The genome *content* (`genomes.md`, `colloid-constitution.md`, `panspermia.txt`),
the skills (`.agents/skills/`), and the per-engine adapters
(`.claude/`, `.kimi/`) are the rest of the kit — read `README.md` at the repo
root for the full map. This demo is the mechanical proof; those are the payload.

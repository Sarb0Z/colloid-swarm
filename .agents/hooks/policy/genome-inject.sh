#!/usr/bin/env bash
# Engine-agnostic policy: stamp a spawned subagent with a genome.
#
# Input  (stdin JSON): {"project_dir": "...", "subagent_type": "..."}
# Output (STDOUT): a JSON object carrying hookSpecificOutput.additionalContext,
#   or nothing. Always exit 0; never blocks.
#
# A SubagentStart *context* policy. The host delivers additionalContext into the
# spawned cell's own transcript before its first prompt, so the treatment is
# applied to every dispatch rather than demanded of the orchestrator and refused
# when it forgets. For an RL environment that is the difference between a
# control arm and a failed run.
#
# Read-only utility types (Explore/Plan/...) carry no personality — a genome on
# a search that cannot write is noise — so they are exempt. The list is the
# `swarm.exempt_subagent_types` config key.
#
# Injection is the whole layer. Nothing checks that a dispatch carries a stamp,
# because the host supplies it: a gate the orchestrator can forget delivered one
# stamp in 165 dispatches, and every block it issued was the orchestrator being
# told to do the injector's job.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
cfg_path="$repo/.agents/config.json"
enabled="$(python3 "$lib/config.py" "$cfg_path" hooks.genome_inject.enabled=true)"
[[ "$enabled" == "no" ]] && exit 0

exempt="$(python3 "$lib/genome-exempt.py" "$cfg_path")"
[[ "$exempt" == "yes" ]] && exit 0

# Sortition with the ledger's anti-repeat, so sequential cells in one fan-out
# condense as different selves. A failure here emits nothing rather than a
# half-formed personality: genome.sh already fails closed on a malformed
# genomes.md, and a cell with no stamp beats a cell with a broken one.
stamp="$("$repo/.agents/genome.sh" 2>/dev/null)" || exit 0
[[ -z "$stamp" ]] && exit 0

printf '%s' "$stamp" | python3 "$lib/emit-context.py" SubagentStart
exit 0

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
# a search that cannot write is noise — so they are exempt. `genome-guard.sh`
# reads the same exemption list, and both are the same `swarm` config key.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
cfg_path="$repo/.agents/config.json"
enabled="$(python3 "$lib/config.py" "$cfg_path" hooks.genome_inject.enabled=true)"
[[ "$enabled" == "no" ]] && exit 0

# genome-guard.py owns the exemption list for both policies.
exempt="$(python3 "$lib/genome-guard.py" "$cfg_path" --exempt)"
[[ "$exempt" == "yes" ]] && exit 0

# Sortition with the ledger's anti-repeat, so sequential cells in one fan-out
# condense as different selves. A failure here emits nothing rather than a
# half-formed personality: genome.sh already fails closed on a malformed
# genomes.md, and a cell with no stamp beats a cell with a broken one.
stamp="$("$repo/.agents/genome.sh" 2>/dev/null)" || exit 0
[[ -z "$stamp" ]] && exit 0

printf '%s' "$stamp" | python3 "$lib/emit-context.py" SubagentStart
exit 0

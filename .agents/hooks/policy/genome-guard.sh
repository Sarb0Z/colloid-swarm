#!/usr/bin/env bash
# Engine-agnostic policy: every substantive subagent dispatch carries exactly
# one genome stamp. This enforces the orchestrator protocol — it blocks a
# dispatch whose prompt is missing (or doubling) the genome the orchestrator was
# supposed to prepend with `.agents/genome.sh`.
#
# For an engine whose SubagentStart event can deliver context into the spawned
# cell, genome-inject.sh replaces this: injecting applies the treatment to every
# dispatch, where a guard only rejects one that forgot. This is the path for an
# engine without that event.
#
# Input  (stdin JSON): {"prompt": "<subagent prompt>", "subagent_type": "..."}
# Output: exit 2 + stderr reason on block; exit 0 otherwise.
#
# Read-only utility agents (Explore/Plan/...) carry no personality — a genome on
# a search that cannot write is noise — so they are exempt. A malformed or
# empty payload fails OPEN (exit 0), matching guard-destructive.sh: a guard that
# cannot read its input must never block on its own blindness.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
cfg_path="$repo/.agents/config.json"
enabled="$(python3 "$lib/config.py" "$cfg_path" hooks.genome_guard.enabled=true)"
[[ "$enabled" == "no" ]] && exit 0

verdict="$(python3 "$lib/genome-guard.py" "$cfg_path")"

case "$verdict" in
  missing)
    printf '%s\n' "This subagent has no genome. Stamp one: run \`.agents/genome.sh\` (sortition by default; pass a name/number to force one, or \`--count N\` for a parallel fan-out) and prepend its output to the subagent's prompt. A swarm of yes-men explores nothing." >&2
    exit 2 ;;
  double)
    printf '%s\n' "This subagent carries more than one genome stamp. Keep exactly one — re-run \`.agents/genome.sh\` once and prepend a single stamp." >&2
    exit 2 ;;
  *)
    exit 0 ;;
esac

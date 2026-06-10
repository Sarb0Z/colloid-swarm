#!/usr/bin/env bash
# Engine-agnostic policy: every substantive subagent dispatch carries exactly
# one genome stamp. A hook cannot inject context into a spawned subagent, so
# this enforces the orchestrator protocol instead of replacing it — it blocks a
# dispatch whose prompt is missing (or doubling) the genome the orchestrator was
# supposed to prepend with `.agents/genome.sh`.
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
cfg_path="$repo/.agents/config.json"
enabled="$(CFG_PATH="$cfg_path" python3 <<'PY'
import json, os
cfg = {}
try:
    with open(os.environ["CFG_PATH"], encoding="utf-8") as f: cfg = json.load(f)
except Exception: pass
print("yes" if cfg.get("hooks", {}).get("genome_guard", {}).get("enabled", True) else "no")
PY
)"
[[ "$enabled" == "no" ]] && exit 0

verdict="$(HOOK_INPUT="$(cat)" CFG_PATH="$cfg_path" python3 <<'PY'
import json, os

try:
    d = json.loads(os.environ.get("HOOK_INPUT") or "{}")
except Exception:
    d = {}
cfg = {}
try:
    with open(os.environ["CFG_PATH"], encoding="utf-8") as f: cfg = json.load(f)
except Exception: pass

# Coerce defensively: a non-string prompt/type must fail open, not crash.
prompt = d.get("prompt")
prompt = prompt if isinstance(prompt, str) else ""
atype  = d.get("subagent_type")
atype  = (atype if isinstance(atype, str) else "").strip().lower()

# Read-only / utility subagent types — no genome expected.
exempt = set(cfg.get("swarm", {}).get("exempt_subagent_types", ["explore", "plan", "claude-code-guide", "statusline-setup"]))
SENTINEL = "⊰ COLLOID GENOME · THE "   # genome.sh emits this as a stamp's first line

if atype in exempt or not prompt.strip():
    print("allow")
else:
    n = sum(1 for line in prompt.splitlines() if line.startswith(SENTINEL))
    print("missing" if n == 0 else "double" if n > 1 else "allow")
PY
)"

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

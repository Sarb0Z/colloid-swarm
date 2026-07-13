#!/usr/bin/env bash
# Engine-agnostic policy: surface deferred work, and re-state the Discovered
# Subprojects policy when a session resumes on compacted context.
#
# Input  (stdin JSON): {"project_dir": "...", "source": "..."}
# Output (STDOUT): a single JSON object carrying
#   hookSpecificOutput.additionalContext. SessionStart injects that field
#   regardless of source; plain stdout is NOT injected for source=compact
#   (anthropics/claude-code#15174), so the structured channel is the robust
#   one. Silent (exit 0, no output) when there is nothing to surface. A
#   context policy, never a gate (no exit 2).
#
#   - Unaddressed .agents/breadcrumbs.md items (markdown "- " bullets).
#   - Compaction (source=compact): the full Discovered Subprojects policy
#     (relocated here from AGENTS.md) + a checkpoint nudge tailored to the
#     trigger word pre-compact.sh left in .agents/.compaction-pending. The
#     marker is consumed (deleted) here; source=compact is the trigger, not
#     the marker's existence.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cfg_path="$repo/.agents/config.json"
enabled="$(CFG_PATH="$cfg_path" python3 <<'PY'
import json, os
cfg = {}
try:
    with open(os.environ["CFG_PATH"], encoding="utf-8") as f: cfg = json.load(f)
except Exception: pass
print("yes" if cfg.get("hooks", {}).get("session_start", {}).get("enabled", True) else "no")
PY
)"
[[ "$enabled" == "no" ]] && exit 0

input="$(cat)"

# The adapter feeds normalizer-built JSON, so this parse cannot fail in practice.
parsed="$(HOOK_INPUT="$input" python3 <<'PY'
import json, os
d = json.loads(os.environ["HOOK_INPUT"] or "{}")
print(d.get("project_dir", ""))
print(d.get("source", ""))
PY
)"
proj="$(printf '%s\n' "$parsed" | sed -n '1p')"
start_source="$(printf '%s\n' "$parsed" | sed -n '2p')"
[[ -z "$proj" ]] && proj="$PWD"

items=""
crumbs="$proj/.agents/breadcrumbs.md"
[[ -f "$crumbs" ]] && items="$(grep -E '^[[:space:]]*-[[:space:]]' "$crumbs" 2>/dev/null || true)"

# source=compact is the trigger. Always consume the PreCompact marker as
# cleanup, but only trust its trigger word on a genuine post-compaction start
# — a marker left by an aborted compaction must not fire the policy on an
# ordinary startup/resume.
is_compact="false"
[[ "$start_source" == "compact" ]] && is_compact="true"

marker="$proj/.agents/.compaction-pending"
trigger="auto"
if [[ -f "$marker" ]]; then
  m="$(head -n1 "$marker" 2>/dev/null || true)"
  rm -f "$marker"
  [[ "$m" =~ ^(auto|manual)$ ]] && trigger="$m"
fi

# Nothing to surface.
[[ -z "$items" && "$is_compact" != "true" ]] && exit 0

body="$(
  if [[ "$is_compact" == "true" ]]; then
    cat <<EOF
Context was just compacted (trigger: $trigger). If you were mid-pivot on a
discovered subproject, checkpoint the current unit now — update the todo list,
note the file/line — and consider recommending a fresh session rather than
working from the compacted summary.

Discovered Subprojects policy (relocated from AGENTS.md; re-stated here since
it is no longer always-loaded):

Mid-session, a new subproject (B) may surface while working on the current
unit (A). Classify it immediately — never drift into B unscoped.

Blocking — A cannot complete correctly without B. Before pivoting:
1. Checkpoint A: update the todo list and note the current file/line. Do not
   commit to checkpoint; commits happen only when the user asks.
2. B becomes the new scoped unit — re-plan and hostile-review it.
3. Finish B end-to-end.
4. Return to A from the checkpoint. If B ran past ~20 turns or triggered a
   context compaction, checkpoint A and recommend the user start a fresh
   session to continue it, rather than working from the compacted summary.

Non-blocking — B is optimization, cleanup, or future work. Do not explore it,
read files for it, or plan it. File one line and return to A immediately:
deferred *work* → .agents/breadcrumbs.md; a standing tradeoff or deferred
*decision* (e.g. "naive here, fine until N>10k") → .agents/debt-log.md under a
stable id, referenced from code as \`debt: <id>\` rather than narrated inline.
If B must be investigated before it can even be classified, delegate that to a
subagent so it runs in an isolated context.

Trivial exception — a fix under ~15 minutes in a file A already touches may be
done inline. Everything else goes through this gate.
EOF
  fi

  if [[ -n "$items" ]]; then
    [[ "$is_compact" == "true" ]] && echo
    count="$(printf '%s\n' "$items" | wc -l | tr -d ' ')"
    echo "Unaddressed breadcrumbs in .agents/breadcrumbs.md (deferred non-blocking work — act on each, or delete the line):"
    if (( count > 10 )); then
      echo "  (10 most recent of $count — prune the file)"
      printf '%s\n' "$items" | tail -n 10
    else
      printf '%s\n' "$items"
    fi
  fi
)"

[[ -z "$body" ]] && exit 0

HOOK_BODY="$body" python3 <<'PY'
import json, os
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": os.environ["HOOK_BODY"],
    }
}))
PY
exit 0

#!/usr/bin/env bash
# Engine-agnostic policy: inject the learning output style, surface deferred
# work, and re-state the Discovered Subprojects policy after compaction.
#
# Input  (stdin JSON): {"project_dir": "...", "source": "..."}
# Output (STDOUT): a single JSON object carrying
#   hookSpecificOutput.additionalContext. SessionStart injects that field
#   regardless of source; plain stdout is NOT injected for source=compact
#   (anthropics/claude-code#15174), so the structured channel is the robust
#   one. Silent (exit 0, no output) when there is nothing to surface. A
#   context policy, never a gate (no exit 2).
#
#   - Learning output style instructions on each session start.
#   - Unaddressed .agents/breadcrumbs.md items (markdown "- " bullets).
#   - Registry MCP servers that are toggled off (name + description), with the
#     sync-mcp.sh enable/disable incantation — the model learns they exist and
#     how to switch them on without paying their tool-schema cost upfront.
#   - Compaction (source=compact): the full Discovered Subprojects policy
#     (relocated here from AGENTS.md) + a checkpoint nudge tailored to the
#     trigger word pre-compact.sh left in .agents/.compaction-pending. The
#     marker is consumed (deleted) here; source=compact is the trigger, not
#     the marker's existence.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cfg_path="$repo/.agents/config.json"
switches="$(CFG_PATH="$cfg_path" python3 <<'PY'
import json, os
cfg = {}
try:
    with open(os.environ["CFG_PATH"], encoding="utf-8") as f: cfg = json.load(f)
except Exception: pass
if not isinstance(cfg, dict):
    cfg = {}
hooks = cfg.get("hooks", {})
if not isinstance(hooks, dict):
    hooks = {}
for key in ("session_start", "learning_output_style"):
    entry = hooks.get(key, {})
    enabled = entry.get("enabled", True) if isinstance(entry, dict) else True
    print("yes" if enabled is not False else "no")
PY
)"
session_start_enabled="$(printf '%s\n' "$switches" | sed -n '1p')"
learning_enabled="$(printf '%s\n' "$switches" | sed -n '2p')"
[[ "$session_start_enabled" == "no" && "$learning_enabled" == "no" ]] && exit 0

input="$(cat)"

# The adapter feeds normalizer-built JSON, so this parse cannot fail in practice.
parsed="$(HOOK_INPUT="$input" python3 <<'PY'
import json, os
d = json.loads(os.environ["HOOK_INPUT"] or "{}")
print(d.get("project_dir", ""))
print(d.get("source", ""))
print(d.get("session_id", ""))
print(d.get("transcript_path", ""))
PY
)"
proj="$(printf '%s\n' "$parsed" | sed -n '1p')"
start_source="$(printf '%s\n' "$parsed" | sed -n '2p')"
session_id="$(printf '%s\n' "$parsed" | sed -n '3p')"
transcript="$(printf '%s\n' "$parsed" | sed -n '4p')"
[[ -z "$proj" ]] && proj="$PWD"

# Seed session-wrap's baseline with the commit this session STARTS from. Its own
# first write happens at the end of turn 1, by which time a turn that implemented
# and committed has already hidden that work inside the baseline. Only this hook
# runs early enough to see the true starting point.
#
# Write when the file is absent, and on a RESUME. source=compact continues a
# session inside one sitting — re-seeding there would erase a ladder mid-flight —
# but a resume picks up a session whose state can be days old, and commits that
# landed from anywhere in between would otherwise be measured as its own work.
#
# The file format is owned by .agents/hooks/policy/session-wrap.sh — read the
# state-file schema in its header before touching these five lines.
ident="${session_id:-$transcript}"
if [[ "$session_start_enabled" == "yes" && -n "$ident" ]] && git -C "$proj" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  seed="$proj/.agents/.wrap-state-$(printf '%s' "$ident" | cksum | tr -d ' ')"
  if [[ ! -e "$seed" || "$start_source" == "resume" ]]; then
    head_sha="$(git -C "$proj" rev-parse -q --verify HEAD 2>/dev/null || true)"
    commits="$(git -C "$proj" rev-list --count HEAD 2>/dev/null || true)"
    [[ "$commits" =~ ^[0-9]+$ ]] || commits=""
    mkdir -p "$proj/.agents" 2>/dev/null || true
    { printf 'none\n\n%s\n%s\n\n' "$commits" "$head_sha" > "$seed"; } 2>/dev/null || true
  fi
fi

items=""
crumbs="$proj/.agents/breadcrumbs.md"
if [[ "$session_start_enabled" == "yes" && -f "$crumbs" ]]; then
  items="$(grep -E '^[[:space:]]*-[[:space:]]' "$crumbs" 2>/dev/null || true)"
fi

# Registry servers that are toggled off: surface them so the model knows they
# exist and can switch them on mid-task. Toggle merge mirrors sync-mcp.sh
# (example base, local per-server override).
mcp_off=""
if [[ "$session_start_enabled" == "yes" ]]; then
  mcp_off="$(PROJ="$proj" python3 <<'PY'
import json, os
agents = os.path.join(os.environ["PROJ"], ".agents")
def load(p):
    try:
        with open(p, encoding="utf-8") as f: value = json.load(f)
        return value if isinstance(value, dict) else {}
    except Exception: return {}
registry = load(os.path.join(agents, "mcp.json")).get("mcpServers", {})
example = load(os.path.join(agents, "config.json.example"))
local = load(os.path.join(agents, "config.json"))
toggles = dict(example.get("mcp", {}).get("servers", {}))
ls = local.get("mcp", {})
if isinstance(ls, dict) and isinstance(ls.get("servers"), dict):
    for name, entry in ls["servers"].items():
        # Per-entry merge: a local {"enabled": ...} flip must not shadow the
        # example's description.
        base = toggles.get(name, {})
        toggles[name] = {**base, **entry} if isinstance(entry, dict) else entry
lines = []
for name in sorted(registry):
    t = toggles.get(name, {})
    if not isinstance(t, dict) or t.get("enabled") is True:
        continue
    desc = t.get("description", "")
    lines.append(f"- {name}" + (f" — {desc}" if desc else ""))
print("\n".join(lines))
PY
)"
fi

# source=compact is the trigger. Always consume the PreCompact marker as
# cleanup, but only trust its trigger word on a genuine post-compaction start
# — a marker left by an aborted compaction must not fire the policy on an
# ordinary startup/resume.
is_compact="false"
[[ "$session_start_enabled" == "yes" && "$start_source" == "compact" ]] && is_compact="true"

marker="$proj/.agents/.compaction-pending"
trigger="auto"
if [[ "$session_start_enabled" == "yes" && -f "$marker" ]]; then
  m="$(head -n1 "$marker" 2>/dev/null || true)"
  rm -f "$marker"
  [[ "$m" =~ ^(auto|manual)$ ]] && trigger="$m"
fi

# Load the teaching contract from one canonical file. A missing playbook must
# not block session startup.
learning_body=""
learning_playbook="$repo/.agents/playbooks/learning-output-style.md"
if [[ "$learning_enabled" == "yes" && -f "$learning_playbook" ]]; then
  learning_body="$(cat "$learning_playbook")"
fi

# Nothing to surface.
[[ -z "$learning_body" && -z "$items" && "$is_compact" != "true" && -z "$mcp_off" ]] && exit 0

body="$(
  if [[ -n "$learning_body" ]]; then
    printf '%s\n' "$learning_body"
  fi

  if [[ "$is_compact" == "true" ]]; then
    [[ -n "$learning_body" ]] && echo
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
    [[ -n "$learning_body" || "$is_compact" == "true" ]] && echo
    count="$(printf '%s\n' "$items" | wc -l | tr -d ' ')"
    echo "Unaddressed breadcrumbs in .agents/breadcrumbs.md (deferred non-blocking work — act on each, or delete the line):"
    if (( count > 10 )); then
      echo "  (10 most recent of $count — prune the file)"
      printf '%s\n' "$items" | tail -n 10
    else
      printf '%s\n' "$items"
    fi
  fi

  if [[ -n "$mcp_off" ]]; then
    [[ -n "$learning_body" || "$is_compact" == "true" || -n "$items" ]] && echo
    echo "Registry MCP servers currently OFF (not connected; the description says why):"
    printf '%s\n' "$mcp_off"
    echo 'If the task needs one: run `.agents/sync-mcp.sh enable <name>`, then ask the user to restart the session (MCP servers connect at startup). Turn it back off with `.agents/sync-mcp.sh disable <name>`.'
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

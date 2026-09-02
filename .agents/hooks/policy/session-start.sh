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
#   - .agents/breadcrumbs.md: every bullet under "## Open decisions" (each
#     waits on the user), then the other bullets capped at the 10 most recent.
#   - Settled decisions: the `### <id>` headings of .agents/decisions.md, so a
#     declined idea is not re-proposed without opening the entry.
#   - The knowledge index, reduced to `date · kind · subject` per line; the
#     summary after the em dash stays in the file.
#   - Registry MCP servers that are toggled off (name + description), with the
#     mcp.py enable/disable incantation — the model learns they exist and
#     how to switch them on without paying their tool-schema cost upfront.
#   - Compaction (source=compact): the full Discovered Subprojects policy
#     (AGENTS.md carries only a one-line copy) + a checkpoint nudge tailored to the
#     trigger word pre-compact.sh left in .agents/.compaction-pending. The
#     marker is consumed (deleted) here; source=compact is the trigger, not
#     the marker's existence.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
switches="$(python3 "$lib/config.py" "$repo/.agents/config.json" \
  hooks.session_start.enabled=true hooks.learning_output_style.enabled=true)"
session_start_enabled="$(printf '%s\n' "$switches" | sed -n '1p')"
learning_enabled="$(printf '%s\n' "$switches" | sed -n '2p')"
[[ "$session_start_enabled" == "no" && "$learning_enabled" == "no" ]] && exit 0

parsed="$(python3 "$lib/payload.py" project_dir source session_id transcript_path)"
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
open=""
crumbs="$proj/.agents/breadcrumbs.md"
if [[ "$session_start_enabled" == "yes" && -f "$crumbs" ]]; then
  # Bullets under "## Open decisions" wait on the user, so every one surfaces;
  # every other bullet is deferred work and takes the cap below.
  open="$(awk '/^## Open decisions/{f=1; next} /^## /{f=0} f && /^[[:space:]]*-[[:space:]]/' "$crumbs" 2>/dev/null || true)"
  items="$(awk '/^## Open decisions/{f=1; next} /^## /{f=0} !f && /^[[:space:]]*-[[:space:]]/' "$crumbs" 2>/dev/null || true)"
fi

decisions=""
decisions_file="$proj/.agents/decisions.md"
if [[ "$session_start_enabled" == "yes" && -f "$decisions_file" ]]; then
  decisions="$(grep -E '^### ' "$decisions_file" 2>/dev/null | sed 's/^### /- /' || true)"
fi

knowledge=""
knowledge_index="$proj/.agents/knowledge/index.md"
if [[ "$session_start_enabled" == "yes" && -f "$knowledge_index" ]]; then
  knowledge="$(grep -E '^- [0-9]{4}-[0-9]{2}-[0-9]{2} ' "$knowledge_index" 2>/dev/null | sed 's/ — .*$//' || true)"
fi

# Surface disabled registry servers so the model can request only what it needs.
mcp_off=""
if [[ "$session_start_enabled" == "yes" ]]; then
  mcp_off="$(python3 "$lib/mcp-off.py" "$proj")"
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
[[ -z "$learning_body" && -z "$open" && -z "$items" && -z "$decisions" && -z "$knowledge" && "$is_compact" != "true" && -z "$mcp_off" ]] && exit 0

body="$(
  # One blank line between sections, none before the first.
  printed=false
  section() {
    if [[ "$printed" == true ]]; then echo; fi
    printed=true
  }

  if [[ -n "$learning_body" ]]; then
    section
    printf '%s\n' "$learning_body"
  fi

  if [[ "$is_compact" == "true" ]]; then
    section
    cat <<EOF
Context was just compacted (trigger: $trigger). If you were mid-pivot on a
discovered subproject, checkpoint the current unit now — update the todo list,
note the file/line — then continue from the summary.

Discovered Subprojects policy (AGENTS.md keeps a one-line compressed copy for
the pre-compaction window; this hook re-states the full policy because a
compacted summary may have dropped it):

Mid-session, a new subproject (B) may surface while working on the current
unit (A). Classify it immediately — never drift into B unscoped.

Blocking — A cannot complete correctly without B. Before pivoting:
1. Checkpoint A: update the todo list and note the current file/line. Do not
   commit to checkpoint; commits happen only when the user asks.
2. B becomes the new scoped unit — re-plan and hostile-review it.
3. Finish B end-to-end.
4. Return to A from the checkpoint.

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

  if [[ -n "$open" ]]; then
    section
    echo "Open decisions in .agents/breadcrumbs.md (each waits on a ruling from the user; ask when the work touches one):"
    printf '%s\n' "$open"
  fi

  if [[ -n "$items" ]]; then
    section
    count="$(printf '%s\n' "$items" | wc -l | tr -d ' ')"
    echo "Unaddressed breadcrumbs in .agents/breadcrumbs.md (deferred non-blocking work — act on each, or delete the line):"
    if (( count > 10 )); then
      # The newest, not the oldest. Items are appended, so the tail is what
      # recent sessions found and deferred, and it is the most likely to
      # intersect the work in hand. An item that has sat unhandled through many
      # sessions is evidence of low value, not of neglect — those wait for a
      # maintenance pass, which reads the file directly rather than through
      # this cap.
      echo "  (10 most recent of $count — prune the file)"
      printf '%s\n' "$items" | tail -n 10
    else
      printf '%s\n' "$items"
    fi
  fi

  if [[ -n "$decisions" ]]; then
    section
    echo "Settled decisions in .agents/decisions.md (open the entry for the why before proposing what it declined):"
    printf '%s\n' "$decisions"
  fi

  if [[ -n "$knowledge" ]]; then
    section
    echo "Knowledge index, .agents/knowledge/index.md (dated observations from outside the repository; read the index line before opening an entry):"
    kcount="$(printf '%s\n' "$knowledge" | wc -l | tr -d ' ')"
    if (( kcount > 12 )); then
      # Newest last in the index, so the tail is the most recent research.
      echo "  (12 most recent of $kcount — read the index)"
      printf '%s\n' "$knowledge" | tail -n 12
    else
      printf '%s\n' "$knowledge"
    fi
  fi

  if [[ -n "$mcp_off" ]]; then
    section
    echo "Registry MCP servers currently OFF (not connected; the description says why):"
    printf '%s\n' "$mcp_off"
    echo 'If the task needs one: run `python3 .agents/mcp.py enable <name>`, then restart the session. Turn it off with `python3 .agents/mcp.py disable <name>`.'
  fi
)"

[[ -z "$body" ]] && exit 0

printf '%s' "$body" | python3 "$lib/emit-context.py" SessionStart
exit 0

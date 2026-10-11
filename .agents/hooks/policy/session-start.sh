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
#   - The work log (hooks.worklog, off by default): the procedure in
#     .agents/playbooks/worklog.md and today's file, or why the configured
#     folder was refused.
#
# `session-start.sh --worklog` prints the work-log resolution alone (see
# resolve_worklog) for session-wrap.sh, so the folder rules live in one place.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"

# The work log, read from the untracked config.json alone: the folder is one
# operator's machine, and a tracked policy.json naming a path outside the
# repository would point every clone at a folder its operator never chose.
# Prints three lines: off | ok | refused; then today's file or the refusal
# reason; then the folder an operator must grant, empty when it is in the tree.
# Off reads no path outside the tree. The folder is never created.
resolve_worklog() {
  python3 - "$repo" "$lib" <<'PY'
import os
import subprocess
import sys
import time

repo, lib = sys.argv[1], sys.argv[2]
sys.path.insert(0, lib)
import config

settings = config._read_json(os.path.join(repo, ".agents", "config.json"))


def emit(status, detail="", grant=""):
    print(status)
    print(detail)
    print(grant)
    sys.exit(0)


if not config.read(settings, "hooks.worklog.enabled", False):
    emit("off")
day = time.strftime("%Y-%m-%d") + ".md"
root = os.path.realpath(repo)
raw = config.read(settings, "hooks.worklog.dir", "")
if raw is None:
    raw = ""
if not isinstance(raw, str):
    emit("refused", "hooks.worklog.dir must be a folder path as a string.")
raw = raw.strip()
if not raw:
    emit("ok", os.path.join(root, ".agents", "worklog", day))

target = os.path.realpath(os.path.join(root, os.path.expanduser(raw)))
hidden = [part for part in target.split(os.sep) if part.startswith(".")]
if hidden:
    emit("refused", f"{target} lies in a hidden folder ({hidden[0]}); hidden folders hold tool and account state.")
parent = os.path.dirname(root)
if not os.path.exists(target):
    emit("refused", f"{target} does not exist. Create it yourself; the hook never creates it.")
if not os.path.isdir(target):
    emit("refused", f"{target} is not a folder.")
if target == root or target.startswith(root + os.sep):
    emit("refused", f"{target} is this repository or inside it. Leave hooks.worklog.dir empty "
                    "to keep the log in .agents/worklog/, which Git ignores.")
if target == parent:
    emit("refused", f"{target} is the folder that holds this repository. Use a subfolder of it, "
                    f"such as {os.path.join(parent, 'worklog')}.")
if not target.startswith(parent + os.sep):
    emit("refused", f"{target} is outside {parent}, the folder that holds this repository.")
if os.path.exists(os.path.join(target, ".git")):
    emit("refused", f"{target} is a Git repository.")
# A bounded walk: a repository up to four levels down is refused; deeper ones
# are not looked for, so a large folder costs at most four levels of listing.
level = [target]
for depth in range(1, 5):
    below = []
    for folder in level:
        try:
            entries = sorted(os.scandir(folder), key=lambda entry: entry.name)
        except OSError as error:
            emit("refused", f"{folder} cannot be listed ({error.strerror}).")
        for entry in entries:
            if entry.is_dir(follow_symlinks=False):
                if os.path.exists(os.path.join(entry.path, ".git")):
                    emit("refused", f"{target} holds a Git repository ({os.path.relpath(entry.path, target)}).")
                below.append(entry.path)
    level = below
env = {name: value for name, value in os.environ.items() if not name.startswith("GIT_")}
inside = subprocess.run(["git", "-C", target, "rev-parse", "--is-inside-work-tree"],
                        capture_output=True, text=True, env=env)
if inside.returncode == 0:
    emit("refused", f"{target} is inside a Git work tree.")
emit("ok", os.path.join(target, day), target)
PY
}

if [[ "${1:-}" == "--worklog" ]]; then
  resolve_worklog
  exit 0
fi

switches="$(python3 "$lib/config.py" "$repo/.agents/config.json" \
  hooks.session_start.enabled=true hooks.learning_output_style.enabled=true)"
session_start_enabled="$(printf '%s\n' "$switches" | sed -n '1p')"
learning_enabled="$(printf '%s\n' "$switches" | sed -n '2p')"
worklog="$(resolve_worklog)" || { echo "session-start: the work-log folder could not be resolved; no work-log context this session" >&2; worklog="off"; }
worklog_status="$(printf '%s\n' "$worklog" | sed -n '1p')"
worklog_detail="$(printf '%s\n' "$worklog" | sed -n '2p')"
worklog_grant="$(printf '%s\n' "$worklog" | sed -n '3p')"
[[ "$session_start_enabled" == "no" && "$learning_enabled" == "no" && "$worklog_status" == "off" ]] && exit 0

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
  # edit-record.sh's attribution record. A fresh start owns nothing yet; a
  # resume or a compaction continues the session, whose edits and commits are
  # still its own work.
  if [[ "$start_source" == "startup" ]]; then
    key="${seed##*/.wrap-state-}"
    rm -f "$proj/.agents/.wrap-edits-$key" "$proj/.agents/.wrap-commits-$key" \
          "$proj/.agents/.wrap-head-$key"-* 2>/dev/null || true
  fi
fi

# The parallel-writers gate tracks live writer cells per session. No cell
# survives the process, so a fresh start or a resume begins with none live;
# a compaction continues the same process, where background cells may still
# be running, and leaves the record alone.
if [[ -n "$session_id" && "$start_source" != "compact" ]]; then
  writers_session="$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9_-')"
  rm -rf "$proj/.agents/.writers-live-$writers_session" "$proj/.agents/.writers-turn-$writers_session" \
         "$proj/.agents/.writers-kinds-$writers_session" \
         "$proj/.agents/.writers-lock-$writers_session" "$proj/.agents/.cells-$writers_session" 2>/dev/null || true
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

# A run mid-flight is the first thing a resumed lead needs to know about;
# the digest is the same one workloop-inbox.sh gives at each prompt.
workloop_digest=""
if [[ -f "$proj/.agents/.workloop-state.json" && -f "$lib/workloop-inbox.py" ]]; then
  workloop_digest="$(python3 "$lib/workloop-inbox.py" "$proj/.agents/.workloop-state.json" "$proj/.agents" "${session_id:-start}" SessionStart "" 2>/dev/null || true)"
fi

worklog_body=""
worklog_playbook="$repo/.agents/playbooks/worklog.md"
if [[ "$worklog_status" == "ok" && -f "$worklog_playbook" ]]; then
  worklog_body="$(cat "$worklog_playbook")"
fi

# Nothing to surface.
[[ -z "$learning_body" && -z "$open" && -z "$items" && -z "$decisions" && -z "$knowledge" && "$is_compact" != "true" && -z "$mcp_off" && -z "$workloop_digest" && "$worklog_status" == "off" ]] && exit 0

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
note the file and line — then continue from the summary.

Discovered Subprojects policy, restated in full because a compacted summary may
have dropped it (AGENTS.md keeps a one-line copy for the pre-compaction window):

Mid-session, a new subproject (B) may surface while you work on the current
unit (A). Classify it immediately — never drift into B unscoped.

Blocking — A cannot complete correctly without B. Before pivoting:
1. Checkpoint A: update the todo list and note the current file and line. Do not
   commit an unfinished A as the checkpoint: every commit builds and passes
   its checks, and the repository's commit rule decides when commits land.
2. Scope B as the new unit; re-plan and hostile-review it.
3. Finish B end-to-end.
4. Return to A from the checkpoint.

Non-blocking — B is optimization, cleanup, or future work. Do not explore it,
read files for it, or plan it. File one line and return to A immediately:
deferred *work* → .agents/breadcrumbs.md; a standing trade-off or deferred
*decision* ("naive here, fine until N>10k") → .agents/debt-log.md under a
stable id, referenced from code as \`debt: <id>\` rather than narrated inline.
If B must be investigated before it can even be classified, delegate that to a
cell so it runs in an isolated context.

Trivial exception — a fix of a few lines in a file A already touches may be
done inline. Everything else goes through this gate.
EOF
  fi

  if [[ "$worklog_status" == "ok" ]]; then
    section
    printf '%s\n\n' "$worklog_body"
    echo "Today's work log: $worklog_detail"
    if [[ -n "$worklog_grant" ]]; then
      echo "Writing there needs write access to $worklog_grant alone. Ask the operator to add it; never edit these settings yourself:"
      echo "  - Claude Code: \"permissions\": {\"additionalDirectories\": [\"$worklog_grant\"]} in .claude/settings.local.json"
      echo "  - Codex: sandbox_workspace_write.writable_roots = [\"$worklog_grant\"] in ~/.codex/config.toml (.agents/mcp.py regenerates the project's .codex/config.toml)"
    fi
  elif [[ "$worklog_status" == "refused" ]]; then
    section
    echo "Work log refused: $worklog_detail"
    echo "Tell the operator the log is off until hooks.worklog.dir in .agents/config.json names an existing folder beside this repository — inside the folder that holds it, not in a Git repository, not hidden — or is left empty to keep the log in .agents/worklog/."
  fi

  if [[ -n "$workloop_digest" ]]; then
    section
    echo "Workloop runs in flight (.agents/.workloop-state.json — lanes, messages, and gates a lead owns):"
    printf '%s\n' "$workloop_digest"
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
    echo "Settled decisions in .agents/decisions.md (read an entry's reasoning before proposing what it declined):"
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
    echo "Registry MCP servers switched off (not connected; the description says why):"
    printf '%s\n' "$mcp_off"
    echo 'If the task needs one: run `python3 .agents/mcp.py enable <name>`, then restart the session. Turn it off with `python3 .agents/mcp.py disable <name>`.'
  fi
)"

[[ -z "$body" ]] && exit 0

printf '%s' "$body" | python3 "$lib/emit-context.py" SessionStart
exit 0

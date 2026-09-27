#!/usr/bin/env bash
# Engine-agnostic policy: two writers never edit one checkout at once outside
# a workloop run.
#
# A single writer edits the main tree — that is the linear case and needs no
# ceremony. The moment a second writer is dispatched while another is live,
# the work is a parallel workflow whether or not anyone called it one, and
# the scaffold's answer is a workloop run: each lane in its own provisioned
# worktree, the composed result verified once, the worktrees removed after.
# An `isolation: worktree` flag alone is not accepted here; it isolates the
# edits but nothing verifies their composition or tears the worktrees down.
#
# Four events share one policy because they share one state file:
#   PreToolUse Agent — a dispatch. A read-only type passes. A prompt whose
#                  first line is READ-ONLY passes. Otherwise the first writer
#                  of a turn passes and is counted; a writer dispatched while
#                  any other writer is counted or live is denied, with the
#                  three commands that make it a lane. A prompt that is a
#                  workloop brief is counted but never denied: it is a lane.
#   PreToolUse Edit/Write, main agent — the lead's own edit while an
#                  uncoordinated writer is live is the same collision from
#                  the other side, and is denied unless a workloop run is
#                  active, in which case the live writers are lanes in their
#                  own worktrees and the main tree is the lead's.
#   SubagentStart — a writer that has started moves from "dispatched this
#                  turn" to "live", so a writer dispatched after the previous
#                  one finished, in the same turn, is sequential and passes.
#   SubagentStop  — the writer is no longer live.
#
# session-start.sh clears the state at startup and resume: no subagent
# survives the process, so a cell that died without a SubagentStop cannot
# deny the next session. Within one session, .agents/.writers-live-<session>
# is the file to delete if a cell is known dead.
#
# Input (stdin JSON): {"project_dir", "event", "session_id", "prompt_id",
#   "tool_name", "tool_input": {...}, "agent_id", "agent_type"}
# Output: PreToolUse — a deny envelope on stdout when the rule fires, silence
#   otherwise. The other events emit nothing.
#
# Writers are everything not on the read-only list below. An unknown persona
# is a writer: a gate that guesses "reader" for a name it has not seen lets
# the second implementer through under a new name. A known reader is trusted
# by name, not by its tool list: reviewer and qa-verifier carry Bash and
# could write, but their contracts forbid it, and denying two QA cells at
# once would cost more than the contention it prevents.
#
# The decision is deny, not ask. guard-publish asks because only the user can
# approve an outward mutation; here the remedy is the agent's own — make the
# dispatch a lane — and a prompt would train the user to click through.
# The operator's override is hooks.parallel_writers.enabled in config.json.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
cfg_path="$repo/.agents/config.json"

READERS="explore explorer plan researcher reviewer qa-verifier claude-code-guide statusline-setup"

payload="$(cat)"
# A malformed toggle keeps the gate on: a broken gate must never silently
# disable itself.
enabled="$(python3 "$lib/config.py" "$cfg_path" hooks.parallel_writers.enabled=true 2>/dev/null || echo yes)"
[[ "$enabled" == "no" ]] && exit 0

{ read -r proj; read -r event; read -r session; read -r prompt_id; read -r agent_id; read -r agent_type; read -r tool_name; read -r tool_type; read -r kind; read -r outside; } < <(
  printf '%s' "$payload" | python3 -c '
import json, os, re, sys
try:
    p = json.load(sys.stdin)
except ValueError:
    p = {}
if not isinstance(p, dict):
    p = {}
ti = p.get("tool_input") or {}
if not isinstance(ti, dict):
    ti = {}
def line(v): print(re.sub(r"[\r\n]", " ", str(v or "")))
def ident(v): print(re.sub(r"[^A-Za-z0-9_-]", "", str(v or "")))
line(p.get("project_dir")); line(p.get("event")); ident(p.get("session_id")); ident(p.get("prompt_id"))
ident(p.get("agent_id")); line(p.get("agent_type")); line(p.get("tool_name"))
line(ti.get("subagent_type") or "general-purpose")
prompt = str(ti.get("prompt") or "")
if re.search(r"WORKLOOP (WORKER|REVIEWER|QA) BRIEF", prompt):
    print("brief")
elif re.match(r"\s*READ-ONLY\b", prompt):
    print("read-only")
else:
    print("plain")
# An edit whose every target lies outside the checkout cannot collide with a
# cell working in it. A relative path is the checkout'"'"'s.
root = os.path.realpath(str(p.get("project_dir") or "."))
paths = [v for v in (ti.get("file_path"), ti.get("notebook_path")) if isinstance(v, str) and v]
paths += [e["file_path"] for e in ti.get("edits") or [] if isinstance(e, dict) and isinstance(e.get("file_path"), str)]
def inside(path):
    full = os.path.realpath(os.path.join(root, os.path.expanduser(path)))
    return full == root or full.startswith(root + os.sep)
print("yes" if paths and not any(inside(x) for x in paths) else "no")')

[[ -n "$session" && -n "$proj" ]] || exit 0
live="$proj/.agents/.writers-live-$session"
turn="$proj/.agents/.writers-turn-$session"
lock="$proj/.agents/.writers-lock-$session"
kinds="$proj/.agents/.writers-kinds-$session"
workloop_state="$proj/.agents/.workloop-state.json"

is_reader() {
  local t; t="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  for r in $READERS; do [[ "$t" == "$r" ]] && return 0; done
  return 1
}

# mkdir is the atomic test-and-set stock macOS has. The hold is milliseconds,
# so a lock older than a minute belongs to a dead hook and is reaped; a hook
# that cannot take the lock in a second proceeds without it rather than
# stalling the dispatch behind it.
held=""
take_lock() {
  local tries=0
  while (( tries < 20 )); do
    if mkdir "$lock" 2>/dev/null; then held=yes; return; fi
    [[ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]] && rm -rf "$lock"
    sleep 0.05; tries=$((tries + 1))
  done
}
release_lock() { [[ -n "$held" ]] && rmdir "$lock" 2>/dev/null || true; }
trap release_lock EXIT

turn_count() {  # <prompt_id> -> writers dispatched this turn and not yet started
  [[ -f "$turn" ]] || { echo 0; return; }
  local recorded; recorded="$(cat "$turn")"
  [[ "${recorded%%	*}" == "$1" ]] && echo "${recorded#*	}" || echo 0
}

# SubagentStart carries the prompt id but not the dispatch prompt, so it cannot
# see a READ-ONLY marker. Every dispatch of a turn therefore records the turn,
# and each counted writer adds its type to a set that nothing consumes. A
# started cell registers when its type is in the set for its turn, or when its
# turn was never recorded: an unknown start is a writer. Consuming the set
# instead would let a reader that starts first take a writer's place and leave
# the writer unregistered.
note_turn() {  # <prompt_id> [writer type]
  local recorded="" types=""
  [[ -f "$kinds" ]] && recorded="$(cat "$kinds")"
  [[ "${recorded%%	*}" == "$1" ]] && types="${recorded#*	}"
  [[ -n "${2:-}" ]] && types="$types $(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  printf '%s\t%s' "$1" "$types" >"$kinds"
}

registers() {  # <prompt_id> <agent_type> -> 0 when the started cell is a writer
  local recorded
  [[ -f "$kinds" ]] || return 0
  recorded="$(cat "$kinds")"
  [[ "${recorded%%	*}" == "$1" ]] || return 0
  [[ " ${recorded#*	} " == *" $(printf '%s' "$2" | tr '[:upper:]' '[:lower:]') "* ]]
}

live_count() {
  # grep -c prints 0 and exits 1 on an empty file, so it cannot sit in a || chain.
  if [[ -f "$live" ]]; then grep -c . "$live" || true; else echo 0; fi
}

workloop_active() {
  [[ -f "$workloop_state" ]] || return 1
  python3 - "$workloop_state" <<'EOF'
import json, sys
try:
    runs = json.load(open(sys.argv[1])).get("runs", {})
except (OSError, ValueError):
    sys.exit(1)
for run in runs.values():
    if run.get("torn_down"):
        continue
    if any(lane.get("state") in ("active", "review", "reopened") for lane in run.get("lanes", {}).values()):
        sys.exit(0)
sys.exit(1)
EOF
}

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
    "$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
}

case "$event" in
  PreToolUse)
    if [[ "$tool_name" == "Agent" || "$tool_name" == "Task" ]]; then
      is_reader "$tool_type" && exit 0
      take_lock
      if [[ "$kind" == "read-only" ]]; then
        note_turn "$prompt_id"
        exit 0
      fi
      pending="$(turn_count "$prompt_id")"
      running="$(live_count)"
      if [[ "$kind" != "brief" ]] && (( pending + running >= 1 )); then
        deny "A second writer (${tool_type}) is being dispatched while another writer is still live. Concurrent writers go through a workloop run, which gives each its own provisioned worktree, verifies the merged result once, and removes the worktrees: .agents/workloop.py init <run> --objective '<goal>' --acceptance '<prose>' --verify '<test command>'; .agents/workloop.py add-lane <run> <lane> --worker ${tool_type} --workspace <new path> --path <owned path>; then dispatch the output of .agents/workloop.py brief <run> <lane> --role worker as this cell's prompt. A cell that only reads may say so: start its prompt with READ-ONLY. Read-only personas (explorer, researcher, reviewer, qa-verifier) pass. isolation: worktree alone is not enough — nothing would verify the composition. If a counted writer is known dead, delete ${live}."
        exit 0
      fi
      if ! printf '%s\t%s' "$prompt_id" "$((pending + 1))" >"$turn" || ! note_turn "$prompt_id" "$tool_type"; then
        deny "The parallel-writers gate could not record this dispatch in ${turn}; fix the .agents directory's permissions and retry."
      fi
    else
      # The lead's own edit while an uncoordinated writer is live.
      [[ "$outside" == "yes" ]] && exit 0
      (( $(live_count) >= 1 )) || exit 0
      workloop_active && exit 0
      deny "A writer cell is live in this checkout and no workloop run is active, so an edit here collides with it. Wait for the cell to finish, or make it a workloop lane in its own worktree (.agents/workloop.py init / add-lane / brief) and edit the main tree freely. If the cell is known dead, delete ${live}."
    fi
    ;;
  SubagentStart)
    is_reader "$agent_type" && exit 0
    [[ -n "$agent_id" ]] || exit 0
    take_lock
    registers "$prompt_id" "$agent_type" || exit 0
    printf '%s\t%s\n' "$agent_id" "$agent_type" >>"$live"
    pending="$(turn_count "$prompt_id")"
    (( pending > 0 )) && printf '%s\t%s' "$prompt_id" "$((pending - 1))" >"$turn" || true
    ;;
  SubagentStop)
    [[ -n "$agent_id" && -f "$live" ]] || exit 0
    take_lock
    grep -v "^$agent_id	" "$live" >"$live.new" 2>/dev/null || true
    mv "$live.new" "$live"
    ;;
esac
exit 0

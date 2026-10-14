#!/usr/bin/env bash
# Engine-agnostic policy: two writers never edit one checkout at once.
#
# A single writer edits the main tree — that is the linear case and needs no
# ceremony. The moment a second writer is dispatched to the checkout while
# another works there, the work is a parallel workflow whether or not anyone
# called it one, and the scaffold's answer is a workloop run: each lane in its
# own provisioned worktree, the composed result verified once, the worktrees
# removed after. An `isolation: worktree` flag alone is not accepted here; it
# isolates the edits but nothing verifies their composition or tears the
# worktrees down.
#
# The rule guards this checkout, not the session. A writer whose prompt places
# it elsewhere — a workloop brief for a lane the controller holds in a
# worktree outside the checkout, or one `WORKSPACE: <absolute path>` line
# naming a directory that neither contains nor lies in the checkout and is no
# worktree or clone of this repository (hooks/lib/writers-payload.py decides)
# — is recorded OUTSIDE and never counts as one of its writers.
#
# "In the checkout" means the nearest Git working tree above a path is the
# checkout's own (hooks/lib/write_targets.py in_checkout). A lane worktree
# nested at .agents/worktrees/<run>/<lane> is its own working tree, so the
# lead's edits there, an OUTSIDE cell's writes there and a brief for such a
# lane all count as outside; a submodule stays the checkout's.
#
# Five events share one policy because they share one state file:
#   PreToolUse Agent — a dispatch. A read-only type passes. A prompt that
#                  opens with READ-ONLY passes, as does one that opens with
#                  NOTES-ONLY where the repository has a product folder
#                  (hooks.product_folder.enabled; denied where it has none,
#                  quoting why when the folder is refused). Either marker is
#                  recorded against the dispatch's tool_use_id
#                  (hooks/lib/cell_markers.py); a marked dispatch that cannot
#                  be recorded, an empty id included, is denied, since it
#                  would otherwise run as a writer. An OUTSIDE dispatch passes
#                  and is recorded the same way. Otherwise the first writer of
#                  a turn passes and is counted; a writer dispatched while any
#                  other writer is counted or live is denied, with the three
#                  commands that make it a lane and why a WORKSPACE line, if
#                  any, was refused. A header or a WORKSPACE line is only text:
#                  the cell is held to it when it writes.
#   PreToolUse Edit/Write, main agent — the lead's own edit inside the
#                  checkout while a writer is live there is the same collision
#                  from the other side, and is denied. OUTSIDE cells are not
#                  live writers, so lanes and WORKSPACE cells leave the main
#                  tree to the lead.
#   PreToolUse Edit/Write, a cell's own — a cell carries the marker its prompt
#                  opened with, found through Claude Code's metadata for the
#                  cell (hooks/lib/cell_markers.py decides). READ-ONLY may
#                  write nothing; NOTES-ONLY only where the product folder
#                  holds the target (hooks/lib/product_folder.py); OUTSIDE
#                  anywhere but inside the checkout. SubagentStart carries no
#                  dispatch id, so a marked cell dispatched beside a writer of
#                  its own type registers at start as that writer would, and
#                  until its first write it blocks more and never allows more.
#                  At that write it leaves the live writers and is counted
#                  marked, so a writer of its turn that has not started is
#                  pending again. A cell with no marker is a writer. A cell
#                  whose metadata cannot be read is denied unless it is a
#                  registered writer, so the gate fails closed exactly where a
#                  marked cell can hide. With no marked dispatch recorded this
#                  session, every cell is a writer and nothing is read.
#   SubagentStart — a cell that registers moves its turn's writers from
#                  "dispatched" to "started", so a writer dispatched after the
#                  previous one finished, in the same turn, is sequential and
#                  passes. A start registers only while its turn has a writer
#                  of its type that has not finished: in a long turn, a marked
#                  cell dispatched after that turn's writers of its type have
#                  stopped never registers.
#   SubagentStop  — the cell leaves the live writers. One that never wrote is
#                  counted marked here if its metadata names a marker.
#
# session-start.sh clears the state at startup and resume: no subagent
# survives the process, so a cell that died without a SubagentStop cannot
# deny the next session. Within one session, .agents/.writers-live-<session>
# is the file to delete if a cell is known dead.
#
# Input (stdin JSON): {"project_dir", "cwd", "event", "session_id", "prompt_id",
#   "tool_name", "tool_input": {...}, "tool_use_id", "transcript_path",
#   "agent_id", "agent_type"}
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
# Limits: the marker link reads Claude Code's cell metadata
# (debt: gate-reads-cell-metadata). Every marker binds the file tools only: a
# marked cell can still write through its shell
# (colloid-shell-writes-skip-post-edit) or through a cell it dispatches. Codex
# and Kimi do not run this gate.
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

{ read -r proj; read -r event; read -r session; read -r prompt_id; read -r agent_id; read -r agent_type; read -r tool_name; read -r tool_type; read -r kind; read -r outside; read -r tool_use_id; read -r transcript; read -r refusal; } < <(
  printf '%s' "$payload" | python3 "$lib/writers-payload.py")

[[ -n "$session" && -n "$proj" ]] || exit 0
live="$proj/.agents/.writers-live-$session"
turn="$proj/.agents/.writers-turn-$session"
lock="$proj/.agents/.writers-lock-$session"
kinds="$proj/.agents/.writers-kinds-$session"
markers="$proj/.agents/.cell-markers-$session"

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

# .writers-turn-<session> holds the latest turn that dispatched a writer:
# "<prompt_id> <dispatched> <started> <marked>", tab-separated — the writers it
# dispatched, its cells that registered at start, and those of them later found
# marked. A start cannot tell a marked cell from a writer of its type, so the
# turn's writers not yet started are the dispatched less the started that were
# not found marked, whatever order its cells start, write and stop in.
turn_count() {  # <prompt_id> -> writers dispatched this turn and not yet started
  local recorded="" id dispatched started marked left
  [[ -f "$turn" ]] && recorded="$(cat "$turn")"
  [[ "${recorded%%	*}" == "$1" ]] || { echo 0; return; }
  IFS=$'\t' read -r id dispatched started marked <<<"$recorded"
  left=$(( ${dispatched:-0} - ${started:-0} + ${marked:-0} ))
  echo $(( left > 0 ? left : 0 ))
}

count_turn() {  # <prompt_id> <dispatched|started|marked>: add one to that count of the turn
  local recorded="" id dispatched=0 started=0 marked=0
  [[ -f "$turn" ]] && recorded="$(cat "$turn")"
  if [[ "${recorded%%	*}" == "$1" ]]; then
    IFS=$'\t' read -r id dispatched started marked <<<"$recorded"
  elif [[ "$2" != dispatched ]]; then
    return 0  # a cell of an earlier turn: that turn's count is gone
  fi
  case "$2" in
    dispatched) dispatched=$(( ${dispatched:-0} + 1 )) ;;
    started) started=$(( ${started:-0} + 1 )) ;;
    marked) marked=$(( ${marked:-0} + 1 )) ;;
  esac
  printf '%s\t%s\t%s\t%s' "$1" "${dispatched:-0}" "${started:-0}" "${marked:-0}" >"$turn"
}

# SubagentStart carries the prompt id but not the dispatch prompt, so it cannot
# see a READ-ONLY marker. Every dispatch of a turn therefore records the turn in
# .writers-kinds-<session>: "<prompt_id> <dispatched> <finished>", tab-separated,
# each a space-separated list of writer types, one entry per writer counted at
# dispatch and per registered writer of the turn that finished unmarked. A
# started cell registers while its type has more dispatched writers than
# finished ones in its turn, or when its turn was never recorded: an unknown
# start is a writer. Consuming a type at start instead would let a marked cell
# that starts first take a writer's place and leave the writer unregistered;
# counting only finishes still lets a long turn's later marked cell pass once
# the writers of its type are done.
kinds_field() {  # <recorded line> <1|2> -> that list
  local id dispatched finished
  IFS=$'\t' read -r id dispatched finished <<<"$1"
  if [[ "$2" == 1 ]]; then printf '%s' "$dispatched"; else printf '%s' "$finished"; fi
}

note_turn() {  # <prompt_id> [writer type]
  local recorded="" dispatched="" finished=""
  [[ -f "$kinds" ]] && recorded="$(cat "$kinds")"
  if [[ "${recorded%%	*}" == "$1" ]]; then
    dispatched="$(kinds_field "$recorded" 1)"; finished="$(kinds_field "$recorded" 2)"
  fi
  [[ -n "${2:-}" ]] && dispatched="$dispatched $(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  printf '%s\t%s\t%s' "$1" "$dispatched" "$finished" >"$kinds"
}

note_finished() {  # <prompt_id> <type>: a registered writer of that turn finished
  local recorded=""
  [[ -f "$kinds" ]] && recorded="$(cat "$kinds")"
  [[ "${recorded%%	*}" == "$1" ]] || return 0  # an earlier turn's record is gone
  printf '%s\t%s\t%s' "$1" "$(kinds_field "$recorded" 1)" \
    "$(kinds_field "$recorded" 2) $(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" >"$kinds"
}

occurrences() {  # <word> <list> -> how many times the word appears in the list
  local n=0 w
  for w in $2; do [[ "$w" == "$1" ]] && n=$((n + 1)); done
  echo "$n"
}

registers() {  # <prompt_id> <agent_type> -> 0 when the started cell is a writer
  local recorded type
  [[ -f "$kinds" ]] || return 0
  recorded="$(cat "$kinds")"
  [[ "${recorded%%	*}" == "$1" ]] || return 0
  type="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  (( $(occurrences "$type" "$(kinds_field "$recorded" 1)") > $(occurrences "$type" "$(kinds_field "$recorded" 2)") ))
}

# Takes a cell off the live writers, only while this hook holds the lock, via
# a temporary file beside the live file so a reader sees one whole file.
# Prints the cell's type and the turn it started in (columns 2 and 3).
# A failure is reported and never fails the hook: a cell left live only
# blocks more.
unregister() {  # <agent_id>
  local entry tmp=""
  entry="$(grep "^$1	" "$live" 2>/dev/null)" || return 0
  [[ -n "$held" ]] || { echo "parallel-writers-gate: the lock is busy, so $1 stays a live writer." >&2; return 0; }
  if tmp="$(mktemp "$live.XXXXXX")" && { grep -v "^$1	" "$live" >"$tmp"; (( $? <= 1 )); } && mv "$tmp" "$live"; then
    printf '%s\n' "$entry" | head -n1 | cut -f2,3
  else
    [[ -z "$tmp" ]] || rm -f "$tmp"
    echo "parallel-writers-gate: could not take $1 off $live; it stays a live writer." >&2
  fi
}

live_count() {
  # grep -c prints 0 and exits 1 on an empty file, so it cannot sit in a || chain.
  if [[ -f "$live" ]]; then grep -c . "$live" || true; else echo 0; fi
}

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
    "$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
}

# Books a cell already taken off the live writers by what it turned out to be:
# a marked cell makes its turn's unstarted writer pending again; an unmarked
# one frees its type in its turn; one whose metadata cannot be read changes
# neither count, so later starts of its type keep registering.
settle() {  # <agent_id> <"type<TAB>turn" from unregister> <marked|unmarked|unknown>
  local type began
  [[ -n "$2" ]] || return 0
  IFS=$'\t' read -r type began <<<"$2"
  case "$3" in
    marked) count_turn "$began" marked || echo "parallel-writers-gate: could not count $1 as marked in $turn." >&2 ;;
    unmarked) note_finished "$began" "$type" || echo "parallel-writers-gate: could not count $1 as finished in $kinds." >&2 ;;
    *) echo "parallel-writers-gate: no dispatch marker could be read for $1, which left the live writers; its turn's counts are unchanged." >&2 ;;
  esac
}

# A registered cell has finished. Takes the lock.
finish() {  # <agent_id>
  local entry state=unmarked status=0
  [[ -n "$1" && -f "$live" ]] && grep -q "^$1	" "$live" || return 0
  take_lock
  entry="$(unregister "$1")"
  [[ -n "$entry" ]] || return 0
  if [[ -f "$markers" ]]; then
    python3 "$lib/cell_markers.py" marked "$proj" "$session" "$transcript" "$1" || status=$?
    case "$status" in
      3) state=marked ;;
      0) state=unmarked ;;
      *) state=unknown ;;
    esac
  fi
  settle "$1" "$entry" "$state"
}

case "$event" in
  PreToolUse)
    if [[ "$tool_name" == "Agent" || "$tool_name" == "Task" ]]; then
      if [[ "$kind" == "notes-only" ]] && ! why="$(python3 "$lib/product_folder.py" root "$repo" 2>&1 >/dev/null)"; then
        if [[ "$why" == *"product_folder.py: "* ]]; then
          deny "This repository enables the product folder, but the folder is refused: ${why##*product_folder.py: } Dispatch it READ-ONLY and write the notes yourself, or make it a writer."
        else
          deny "This repository has no product folder enabled (hooks.product_folder.enabled in .agents/config.json${why:+; $why}). Dispatch it READ-ONLY and write the notes yourself, or make it a writer."
        fi
        exit 0
      fi
      is_reader "$tool_type" && exit 0
      take_lock
      if [[ "$kind" != "plain" ]]; then
        marker="$kind"; [[ "$kind" == "brief" || "$kind" == "workspace" ]] && marker=outside
        if ! note_turn "$prompt_id" || ! python3 "$lib/cell_markers.py" record "$proj" "$session" "$tool_use_id" "$marker"; then
          deny "The parallel-writers gate could not record this ${kind} dispatch; without the record the cell would run as a writer. The dispatch needs a tool_use_id and a writable .agents directory; retry once both hold."
        fi
        exit 0
      fi
      pending="$(turn_count "$prompt_id")"
      running="$(live_count)"
      if (( pending + running >= 1 )); then
        deny "A second writer (${tool_type}) is being dispatched to this checkout while another writer works in it.${refusal:+ Its WORKSPACE line was not accepted: ${refusal}.} Check the shape first (the workloop skill's guide): one writer with read-only cells around it is the default; parallel slices suit disjoint files, about three writers at most. Concurrent writers in one repository go through a workloop run, which provisions a worktree per writer, verifies the merged result once, and removes the worktrees: .agents/workloop.py init <run> --objective '<goal>' --acceptance '<prose>' --verify '<test command>'; .agents/workloop.py add-lane <run> <lane> --worker ${tool_type} --path <owned path> (the worktree goes to .agents/worktrees/<run>/<lane>); then dispatch the output of .agents/workloop.py brief <run> <lane> --role worker as this cell's prompt. isolation: worktree alone is not enough — nothing would verify the composition. A cell that works in a separate directory, no copy of this repository, says so with one prompt line, WORKSPACE: <absolute path>, and may then write anywhere but this checkout. A cell that only reads may say so: start its prompt with READ-ONLY; one that also writes notes in the product folder starts NOTES-ONLY. The read-only personas (explorer, researcher, reviewer, qa-verifier) pass. If a counted writer is known dead, delete ${live}."
        exit 0
      fi
      if ! count_turn "$prompt_id" dispatched || ! note_turn "$prompt_id" "$tool_type"; then
        deny "The parallel-writers gate could not record this dispatch in ${turn}; fix the .agents directory's permissions and retry."
      fi
    elif [[ -n "$agent_id" ]]; then
      # A cell's own write: its dispatch marker decides, before any bookkeeping.
      is_reader "$agent_type" && exit 0
      [[ -f "$markers" ]] || exit 0
      status=0
      reason="$(printf '%s' "$payload" | python3 "$lib/cell_markers.py" decide "$repo" "$proj" "$session" "$transcript" "$agent_id")" || status=$?
      if (( status != 0 && status != 3 )); then
        reason="The parallel-writers gate could not read this cell's dispatch marker (cell_markers.py exited ${status}), so it cannot tell whether the cell may write. Retry, or dispatch it as a writer."
      fi
      [[ -z "$reason" ]] || deny "$reason"
      # A marked cell is no writer, whether or not it registered at start.
      if (( status == 3 )) && [[ -f "$live" ]] && grep -q "^$agent_id	" "$live"; then
        take_lock
        settle "$agent_id" "$(unregister "$agent_id")" marked
      fi
    else
      # The lead's own edit while a writer works in the checkout.
      [[ "$outside" == "yes" ]] && exit 0
      (( $(live_count) >= 1 )) || exit 0
      deny "A writer cell is live in this checkout, so an edit here collides with it. Wait for the cell to finish, or make it a workloop lane in its own worktree (.agents/workloop.py init / add-lane / brief), or give it a WORKSPACE outside this checkout, and edit the main tree freely. If the cell is known dead, delete ${live}."
    fi
    ;;
  SubagentStart)
    is_reader "$agent_type" && exit 0
    [[ -n "$agent_id" ]] || exit 0
    take_lock
    registers "$prompt_id" "$agent_type" || exit 0
    count_turn "$prompt_id" started || echo "parallel-writers-gate: could not count $agent_id's start in $turn." >&2
    # Column 3 names the turn the cell started in.
    printf '%s\t%s\t%s\n' "$agent_id" "$agent_type" "$prompt_id" >>"$live" || echo "parallel-writers-gate: could not register writer $agent_id in $live." >&2
    ;;
  SubagentStop)
    # A marked cell that stops before its first write is counted as that write
    # would count it.
    finish "$agent_id"
    ;;
esac
exit 0

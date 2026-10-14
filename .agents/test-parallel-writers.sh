#!/usr/bin/env bash
# Firing tests for the parallel-writers gate: a second writer dispatched to the
# checkout while another works in it is denied; a cell placed outside it (a
# workloop lane, a WORKSPACE line) passes uncounted; readers and sequential
# writers pass. A cell dispatched READ-ONLY, NOTES-ONLY or outside is held to
# that when it writes.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

dir="$scratch/fixture"
mkdir -p "$dir/.agents/hooks/policy" "$dir/.agents/hooks/lib"
cp "$repo/.agents/hooks/policy/parallel-writers-gate.sh" "$dir/.agents/hooks/policy/"
cp "$repo"/.agents/hooks/lib/{config,product_folder,cell_markers,write_targets,writers-payload}.py "$dir/.agents/hooks/lib/"
printf '{"hooks":{"parallel_writers":{"enabled":true}}}\n' > "$dir/.agents/config.json"
gate="$dir/.agents/hooks/policy/parallel-writers-gate.sh"

dispatch() {  # <prompt_id> <subagent_type> [prompt] -> stdout
  printf '{"project_dir":"%s","event":"PreToolUse","session_id":"s1","prompt_id":"%s","tool_name":"Agent","tool_use_id":"tu-%s","tool_input":{"subagent_type":"%s","prompt":%s}}' \
    "$dir" "$1" "$RANDOM$RANDOM" "$2" "$(printf '%s' "${3:-do the thing}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" | bash "$gate"
}
edit() {  # <prompt_id> -> stdout (the lead editing the main tree)
  printf '{"project_dir":"%s","event":"PreToolUse","session_id":"s1","prompt_id":"%s","tool_name":"Edit","tool_input":{"file_path":"src/x.py"}}' "$dir" "$1" | bash "$gate"
}
start() {  # <agent_id> <agent_type> <prompt_id>
  printf '{"project_dir":"%s","event":"SubagentStart","session_id":"s1","prompt_id":"%s","agent_id":"%s","agent_type":"%s"}' "$dir" "$3" "$1" "$2" | bash "$gate"
}
stop() {  # <agent_id> <agent_type>; these cells carry no metadata, which the stop reports on stderr
  printf '{"project_dir":"%s","event":"SubagentStop","session_id":"s1","agent_id":"%s","agent_type":"%s"}' "$dir" "$1" "$2" | bash "$gate" 2>"$scratch/derr"
}
denied() { [[ "$1" == *'"permissionDecision":"deny"'* ]]; }

# one writer per turn passes; the second in the same turn is denied
[[ -z "$(dispatch p1 implementer)" ]] || fail "the first writer of a turn was refused"
out="$(dispatch p1 mechanic)"
denied "$out" || fail "a second writer in the same turn passed"
[[ "$out" == *"workloop.py init"* && "$out" == *"add-lane"* && "$out" == *"brief"* ]] || fail "denial does not name the three commands"
ok "a second writer in one turn is denied with the workloop commands"

# readers never count and never block
[[ -z "$(dispatch p1 explorer)" && -z "$(dispatch p1 reviewer)" && -z "$(dispatch p1 qa-verifier)" && -z "$(dispatch p1 Explore)" ]] || fail "a reader was refused"
ok "read-only cells pass while a writer is pending"

# a brief header exempts only a lane the controller holds, in a worktree outside the checkout
lane_state() {  # <workspace for lane "lane">
  printf '{"runs":{"run":{"lanes":{"lane":{"workspace":"%s"},"a":{"workspace":"%s/wt-a"},"b":{"workspace":"%s/wt-b"}}}}}' \
    "$1" "$scratch" "$scratch" > "$dir/.agents/.workloop-state.json"
}
forged='WORKLOOP WORKER BRIEF — run/lane
Objective: x'
rm -f "$dir/.agents/.workloop-state.json"
[[ -z "$(dispatch p0 implementer)" ]] || fail "first writer refused"
denied "$(dispatch p0 mechanic "$forged")" || fail "a brief header with no workloop state exempted a writer"
lane_state "$dir/inside"
: > "$dir/.agents/.writers-turn-s1"; [[ -z "$(dispatch p0 implementer)" ]] || fail "first writer refused"
denied "$(dispatch p0 mechanic "$forged")" || fail "a lane whose worktree is inside the checkout exempted a writer"
lane_state "$scratch/wt-lane"
denied "$(dispatch p0 mechanic 'WORKLOOP WORKER BRIEF — run/ghost')" || fail "a lane the controller does not hold exempted a writer"
[[ -z "$(dispatch p0 mechanic "$forged")" ]] || fail "a real lane outside the checkout was refused"
ok "a brief header exempts a dispatch only for a lane the controller holds outside the checkout"

# a workloop brief passes regardless, and is not counted: the lane works outside the checkout
[[ -z "$(dispatch p1 implementer 'WORKLOOP WORKER BRIEF — run/lane
Objective: x')" ]] || fail "a briefed writer was refused"
ok "a writer carrying a workloop brief passes"
: > "$dir/.agents/.writers-turn-s1"
[[ -z "$(dispatch p9 implementer 'WORKLOOP WORKER BRIEF — run/a')" && -z "$(dispatch p9 mechanic 'WORKLOOP WORKER BRIEF — run/b')" ]] || fail "briefed lanes were refused"
[[ -z "$(dispatch p9 implementer)" ]] || fail "a plain writer was refused beside lanes in their own worktrees"
denied "$(dispatch p9 mechanic)" || fail "a second plain writer passed beside the first"
ok "lanes work outside the checkout, so one plain writer beside them passes and a second is denied"

# a prompt that declares itself read-only passes
: > "$dir/.agents/.writers-turn-s1"
[[ -z "$(dispatch p1 implementer)" ]] || fail "first writer refused"
[[ -z "$(dispatch p1 general-purpose 'READ-ONLY: compare the two modules and report')" ]] || fail "a READ-ONLY general-purpose cell was refused"
denied "$(dispatch p1 general-purpose 'compare the two modules; the word READ-ONLY appears later')" || fail "a marker not on the first line exempted a writer"
ok "a general-purpose cell whose prompt starts READ-ONLY passes; the marker must lead"

# a persona that writes is never a reader, whatever its name suggests
denied "$(dispatch p1 learning-reporter)" || fail "learning-reporter passed beside a live writer"
ok "learning-reporter counts as a writer"

# an unknown persona is a writer
denied "$(dispatch p1 some-new-cell)" || fail "an unknown persona was treated as a reader"
ok "an unknown persona counts as a writer"

# sequential writers in one turn pass: the first starts and stops before the second
start a1 implementer p1
denied "$(dispatch p1 mechanic)" || fail "a writer passed while another was live"
stop a1 implementer
[[ -z "$(dispatch p1 mechanic)" ]] || fail "a sequential writer was refused after the previous one stopped"
ok "a writer dispatched after the previous one stopped passes"

# a background writer still live blocks the next turn's writer
start a2 mechanic p1
denied "$(dispatch p2 implementer)" || fail "a live background writer did not block the next turn"
stop a2 mechanic
[[ -z "$(dispatch p2 implementer)" ]] || fail "a new turn's writer was refused with nothing live"
ok "a live background writer blocks a later turn until it stops"

# two dispatches racing in one message: exactly one passes
: > "$scratch/race"
for i in 1 2 3 4; do (dispatch p3 implementer >> "$scratch/race") & done; wait
[[ "$(grep -c deny "$scratch/race")" -eq 3 ]] || fail "racing dispatches: expected 3 denials, got $(grep -c deny "$scratch/race")"
ok "of four racing writer dispatches exactly one passes"

# the lead's own edit while a writer is live in the checkout is denied, whatever
# workloop run is active: a lane works elsewhere and is never a live writer here
: > "$dir/.agents/.writers-turn-s1"
[[ -z "$(edit p5)" ]] || fail "an edit with nothing live was refused"
start a5 implementer p5
denied "$(edit p5)" || fail "the lead edited beside a live writer"
printf '{"version":1,"runs":{"r":{"lanes":{"l":{"state":"active"}}}}}' > "$dir/.agents/.workloop-state.json"
denied "$(edit p5)" || fail "an active workloop run freed the lead beside a plain writer"
rm "$dir/.agents/.workloop-state.json"; stop a5 implementer
[[ -z "$(edit p5)" ]] || fail "an edit after the writer stopped was refused"
ok "the lead's edit is denied beside a live writer, whatever workloop run is active"

# a WORKSPACE line that is not plainly elsewhere is refused, and the denial says why
rm -f "$dir/.agents/.writers-"* "$dir/.agents/.cell-markers-"*
git init -q "$dir"; git -C "$dir" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
git clone -q "$dir" "$scratch/clone"
git -C "$dir" worktree add -q "$scratch/wt-own" 2>/dev/null
mkdir -p "$dir/sub" "$scratch/copy-a" "$scratch/copy-b"
for ws in "$dir/sub" "$scratch" "/" "$scratch/missing" "relative/path" "~" "$scratch/clone" "$scratch/wt-own"; do
  : > "$dir/.agents/.writers-turn-s1"
  [[ -z "$(dispatch p12 implementer)" ]] || fail "first writer refused"
  out="$(dispatch p12 mechanic "WORKSPACE: $ws")"
  denied "$out" && [[ "$out" == *"WORKSPACE line was not accepted"* ]] || fail "WORKSPACE $ws was accepted ($out)"
done
: > "$dir/.agents/.writers-turn-s1"
[[ -z "$(dispatch p12 implementer)" ]] || fail "first writer refused"
denied "$(dispatch p12 mechanic "WORKSPACE: $scratch/copy-a
WORKSPACE: $scratch/copy-b")" || fail "two WORKSPACE lines were accepted"
[[ -z "$(dispatch p12 mechanic "build it
WORKSPACE: $scratch/copy-a")" ]] || fail "a WORKSPACE in an unrelated directory was refused beside a writer"
[[ -z "$(GIT_DIR="$dir/.git" dispatch p12 mechanic "WORKSPACE: $scratch/copy-b")" ]] || fail "an inherited GIT_DIR made an unrelated WORKSPACE read as this repository"
git -C "$dir" worktree remove --force "$scratch/wt-own"; rm -rf "$dir/.git" "$dir/sub" "$dir/.agents/.writers-"* "$dir/.agents/.cell-markers-"*
ok "a WORKSPACE inside, above, missing, relative, unexpanded, doubled, or a clone or worktree of this repository is refused; an unrelated one passes, whatever GIT_DIR the session inherited"

# a READ-ONLY generic cell that starts never registers, so the lead edits beside it
rm -f "$dir/.agents/.writers-"*
[[ -z "$(dispatch p7 general-purpose 'READ-ONLY: mine the logs')" ]] || fail "READ-ONLY dispatch refused"
start r7 general-purpose p7
[[ -z "$(edit p7)" ]] || fail "a started READ-ONLY cell blocked the lead's edit"
stop r7 general-purpose
ok "a started READ-ONLY generic cell does not register as a writer"

# a writer and a READ-ONLY cell of one type in one turn: both register, in
# either start order, so the writer stays live after the reader stops
for order in reader-first writer-first; do
  rm -f "$dir/.agents/.writers-"*
  [[ -z "$(dispatch p8 general-purpose 'READ-ONLY: look around')" ]] || fail "READ-ONLY dispatch refused"
  [[ -z "$(dispatch p8 general-purpose 'change the module')" ]] || fail "first writer refused"
  if [[ "$order" == reader-first ]]; then start r8 general-purpose p8; start w8 general-purpose p8
  else start w8 general-purpose p8; start r8 general-purpose p8; fi
  stop r8 general-purpose
  denied "$(edit p8)" || fail "$order: the writer went unregistered once the reader stopped"
  stop w8 general-purpose
  [[ -z "$(edit p8)" ]] || fail "$order: edit refused after both stopped"
done
ok "a mixed reader and writer turn keeps the writer registered in either start order"

# a start whose turn was never recorded registers: an unknown start is a writer
rm -f "$dir/.agents/.writers-"*
start u1 general-purpose p-unknown
denied "$(edit p-unknown)" || fail "a start with no recorded dispatch did not register"
stop u1 general-purpose
ok "a start whose dispatch was never recorded counts as a writer"

# an edit whose every target lies outside the checkout passes beside a live writer
[[ -z "$(dispatch p10 implementer)" ]] || fail "writer refused"
start w10 implementer p10
outside_edit() {
  printf '{"project_dir":"%s","event":"PreToolUse","session_id":"s1","prompt_id":"p10","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$dir" "$1" | bash "$gate"
}
[[ -z "$(outside_edit "$scratch/plan.md")" ]] || fail "an edit outside the checkout was refused"
denied "$(outside_edit "$dir/src/y.py")" || fail "an absolute path inside the checkout passed"
denied "$(outside_edit "../fixture/src/y.py")" || fail "a relative path back into the checkout passed"
stop w10 implementer
ok "an edit outside the checkout passes; one inside is still denied"

# a broken toggle keeps the gate on; a malformed payload does not crash it
printf 'not json' > "$dir/.agents/config.json"
: > "$dir/.agents/.writers-turn-s1"
[[ -z "$(dispatch p6 implementer)" ]] || fail "first writer refused under a broken config"
denied "$(dispatch p6 mechanic)" || fail "a broken config turned the gate off"
printf '{"hooks":{"parallel_writers":{"enabled":true}}}\n' > "$dir/.agents/config.json"
[[ -z "$(printf 'not json' | bash "$gate")" ]] || fail "a malformed payload produced output"
ok "a broken toggle keeps the gate on and a malformed payload is ignored"

# a reader stop never edits the live file; a stop for an unknown id is harmless
stop zzz implementer; stop zzz explorer
ok "stray stops are ignored"

# --- READ-ONLY and NOTES-ONLY cells ------------------------------------------
# A checkout inside a product folder under a scratch HOME, with the switch on.
home="$(cd "$scratch" && pwd -P)/home"
pf="$home/product"
nf="$pf/repo"
mkdir -p "$nf/.git" "$nf/.agents/hooks/policy" "$nf/.agents/hooks/lib" "$nf/src" "$pf/notes" "$pf/.vercel" "$pf/sibling/.git" "$pf/sibling/src"
cp "$repo/.agents/hooks/policy/parallel-writers-gate.sh" "$nf/.agents/hooks/policy/"
cp "$repo"/.agents/hooks/lib/{config,product_folder,cell_markers,write_targets,writers-payload}.py "$nf/.agents/hooks/lib/"
printf '{"hooks":{"product_folder":{"enabled":true}}}\n' > "$nf/.agents/config.json"
ngate="$nf/.agents/hooks/policy/parallel-writers-gate.sh"
transcripts="$scratch/transcripts"
subagents="$transcripts/s2/subagents"
nlive="$nf/.agents/.writers-live-s2"

# nfire key=value ... -> stdout; stderr lands in $scratch/gerr
nfire() {
  local args=(--arg project_dir "$nf" --arg session_id s2 --arg transcript_path "$transcripts/main.jsonl") pair
  for pair in "$@"; do args+=(--arg "${pair%%=*}" "${pair#*=}"); done
  jq -nc "${args[@]}" '$ARGS.named
    | .tool_input = ({subagent_type, prompt, file_path} | with_entries(select(.value != null)))
    | del(.subagent_type, .prompt, .file_path)' | env HOME="$home" bash "$ngate" 2>"$scratch/gerr"
}
ndispatch() { nfire event=PreToolUse tool_name=Agent prompt_id="$1" subagent_type="$2" prompt="$3" tool_use_id="$4"; }
nstart() { nfire event=SubagentStart prompt_id="$3" agent_id="$1" agent_type="$2" >/dev/null; }
nstop() { nfire event=SubagentStop agent_id="$1" agent_type="$2" >/dev/null; }
nwrite() { nfire event=PreToolUse tool_name=Write agent_id="$1" agent_type="$2" file_path="$3"; }
nlead() { nfire event=PreToolUse tool_name=Edit prompt_id="$1" file_path="$2"; }
meta() {  # <agent_id> <tool_use_id>: Claude Code's record of a running cell
  mkdir -p "$subagents"
  printf '{"agentType":"general-purpose","description":"d","toolUseId":"%s","spawnDepth":1}\n' "$2" > "$subagents/agent-$1.meta.json"
}
reset() { rm -rf "$nf/.agents/".writers-* "$nf/.agents/".cell-markers-* "$transcripts"; }
live_lines() { if [[ -f "$nlive" ]]; then grep -c . "$nlive" || true; else echo 0; fi; }

# dispatch: the marker passes beside a live writer, and a second plain writer is refused
reset
[[ -z "$(ndispatch p1 general-purpose 'change the module' tu1)" ]] || fail "the first writer was refused"
nstart w1 general-purpose p1
[[ -z "$(ndispatch p2 general-purpose 'NOTES-ONLY: inventory the vendors' tu2)" ]] || fail "a NOTES-ONLY dispatch was refused beside a live writer"
[[ -z "$(ndispatch p2 general-purpose 'READ-ONLY: read the logs' tu3)" ]] || fail "a READ-ONLY dispatch was refused beside a live writer"
out="$(ndispatch p2 general-purpose 'change another module' tu4)"
denied "$out" || fail "a plain writer passed beside a live writer and two marked cells"
[[ "$out" == *NOTES-ONLY* && "$out" == *READ-ONLY* ]] || fail "the second-writer denial does not name both markers"
grep -q $'^tu2\tNOTES-ONLY$' "$nf/.agents/.cell-markers-s2" && grep -q $'^tu3\tREAD-ONLY$' "$nf/.agents/.cell-markers-s2" \
  || fail "the markers were not recorded: $(cat "$nf/.agents/.cell-markers-s2")"
! grep -q tu4 "$nf/.agents/.cell-markers-s2" || fail "a plain writer's dispatch was recorded as marked"
ok "NOTES-ONLY and READ-ONLY dispatches pass beside a live writer and are recorded; the denial names both"

# where the repository has no product folder, NOTES-ONLY is refused, even with nothing live
rm -f "$dir/.agents/.writers-"*
out="$(dispatch p20 general-purpose 'NOTES-ONLY: inventory the vendors')"
denied "$out" && [[ "$out" == *"no product folder"* ]] || fail "a NOTES-ONLY dispatch passed where the switch is off"
denied "$(dispatch p20 reviewer 'NOTES-ONLY: inventory the vendors')" || fail "a reader persona's NOTES-ONLY dispatch passed where the switch is off"
ok "a NOTES-ONLY dispatch is refused where the switch is off"

# a marked cell's own writes, against the checkout, the product folder, a sibling repository and /tmp
for marker in READ-ONLY NOTES-ONLY; do
  reset
  [[ -z "$(ndispatch p3 general-purpose "$marker: do the thing" tu-$marker)" ]] || fail "$marker dispatch refused"
  meta c3 "tu-$marker"; nstart c3 general-purpose p3
  for target in "$nf/src/x.md" "$pf/sibling/src/x.md" "/tmp/gate-test-x.md" "$pf/.vercel/x" "$pf/notes/.env" "$pf/notes/AGENTS.md" \
                "$pf/tools/x.md" "$pf/notes/run.sh" "$pf/notes/x.md"; do
    out="$(nwrite c3 general-purpose "$target")"
    if [[ "$marker" == NOTES-ONLY && "$target" == "$pf/notes/x.md" ]]; then
      [[ -z "$out" ]] || fail "NOTES-ONLY: a write in the product folder was refused ($out)"
    else
      denied "$out" || fail "$marker: a write to $target passed"
    fi
  done
done
ok "READ-ONLY writes nowhere; NOTES-ONLY writes only in the product folder, not in a checkout, hidden folder, instruction file or risky part"

# a marked cell registered as a live writer (same turn, same type) leaves the live set at its first write
for marker in READ-ONLY NOTES-ONLY; do
  reset
  [[ -z "$(ndispatch p4 general-purpose 'change the module' tuw)" ]] || fail "writer refused"
  [[ -z "$(ndispatch p4 general-purpose "$marker: write up" tum)" ]] || fail "$marker dispatch refused"
  meta w4 tuw; meta m4 tum
  nstart w4 general-purpose p4; nstart m4 general-purpose p4
  [[ "$(live_lines)" -eq 2 ]] || fail "$marker: expected both cells registered at start, got $(live_lines)"
  nwrite m4 general-purpose "$pf/notes/x.md" >/dev/null
  [[ "$(live_lines)" -eq 1 ]] && grep -q '^w4	' "$nlive" || fail "$marker: the marked cell stayed a live writer after its first write"
  denied "$(nlead p4 "$nf/src/x.py")" || fail "$marker: the lead edited beside the live writer"
  nstop w4 general-purpose
  [[ -z "$(nlead p4 "$nf/src/x.py")" ]] || fail "$marker: the demoted cell still blocked the lead"
done
ok "a marked cell registered at start is removed from the live writers at its first write"

# unknown metadata: a registered writer is left alone, any other cell is refused
reset
[[ -z "$(ndispatch p5 general-purpose 'change the module' tuw5)" ]] || fail "writer refused"
[[ -z "$(ndispatch p5 general-purpose 'READ-ONLY: look' tur5)" ]] || fail "READ-ONLY dispatch refused"
nstart w5 general-purpose p5
[[ -z "$(nwrite w5 general-purpose "$nf/src/x.py")" ]] || fail "a registered writer with unreadable metadata was refused"
[[ -s "$scratch/gerr" ]] || fail "a registered writer with unreadable metadata passed silently"
nstop w5 general-purpose
reset
[[ -z "$(ndispatch p6 general-purpose 'READ-ONLY: look' tu6)" ]] || fail "READ-ONLY dispatch refused"
nstart u6 general-purpose p6
[[ "$(live_lines)" -eq 0 ]] || fail "a marked cell registered although its type was never counted"
out="$(nwrite u6 general-purpose "$pf/notes/x.md")"
denied "$out" && [[ "$out" == *"agent-u6.meta.json"* ]] || fail "an unregistered cell with no metadata was not refused with the metadata path ($out)"
mkdir -p "$subagents"; printf 'not json' > "$subagents/agent-u6.meta.json"
denied "$(nwrite u6 general-purpose "$pf/notes/x.md")" || fail "an unregistered cell with unparseable metadata was not refused"
printf '{"agentType":"x"}' > "$subagents/agent-u6.meta.json"
denied "$(nwrite u6 general-purpose "$pf/notes/x.md")" || fail "an unregistered cell whose metadata lacks toolUseId was not refused"
ok "unreadable metadata: a registered writer passes with a notice; any other cell is denied naming the metadata path"

# an unmarked writer is untouched; so is a reader persona, whatever the record says
reset
[[ -z "$(ndispatch p7 general-purpose 'change the module' tuw7)" ]] || fail "writer refused"
meta w7 tuw7; nstart w7 general-purpose p7
[[ -z "$(nwrite w7 general-purpose "$nf/src/x.py")" ]] || fail "an unmarked writer was refused (no ledger yet)"
[[ -z "$(ndispatch p7b general-purpose 'READ-ONLY: look' tu7)" ]] || fail "READ-ONLY dispatch refused"
[[ -z "$(nwrite w7 general-purpose "$nf/src/x.py")" ]] || fail "an unmarked writer was refused beside a marked cell's record"
[[ "$(live_lines)" -eq 1 ]] || fail "an unmarked writer left the live writers"
meta e7 tu7; nstart e7 explorer p7b
[[ -z "$(nwrite e7 explorer "$nf/src/x.py")" ]] || fail "a reader persona was decided by a marker"
ok "an unmarked writer and a reader persona keep today's behavior"

# a dispatch whose marker cannot be recorded is refused, not run as a writer
reset
mkdir -p "$nf/.agents/.cell-markers-s2"
out="$(ndispatch p8 general-purpose 'READ-ONLY: look' tu8)"
denied "$out" && [[ "$out" == *"could not record"* ]] || fail "an unrecordable marker did not refuse the dispatch ($out)"
rm -rf "$nf/.agents/.cell-markers-s2"
ok "a marker that cannot be recorded refuses the dispatch"

# a marked dispatch with no id to record it under is refused, as is one whose
# .agents cannot be written; either way the gate answers with an envelope
reset
for id in "" '!!' ; do
  out="$(ndispatch p9 general-purpose 'READ-ONLY: look' "$id")"
  denied "$out" && [[ "$out" == *"could not record"* ]] || fail "a READ-ONLY dispatch with the id '$id' was not refused ($out)"
done
[[ ! -s "$nf/.agents/.cell-markers-s2" ]] || fail "an empty id was recorded: $(cat "$nf/.agents/.cell-markers-s2")"
chmod a-w "$nf/.agents"
out="$(ndispatch p9 general-purpose 'NOTES-ONLY: inventory' tu9)" || { chmod u+w "$nf/.agents"; fail "the gate exited non-zero on an unwritable .agents"; }
chmod u+w "$nf/.agents"
denied "$out" && [[ "$out" == *"could not record"* ]] || fail "a NOTES-ONLY dispatch passed with .agents unwritable ($out)"
ok "a marked dispatch with an empty id, or an unwritable .agents, is refused with an envelope"

# with no marked dispatch recorded this session, a cell's write is a writer's and reads nothing
reset
[[ -z "$(nwrite u10 general-purpose "$nf/src/x.md")" ]] || fail "a cell with no metadata was refused although no marked dispatch was recorded"
ok "no marker record: a cell's write passes before any metadata read"

# a NOTES-ONLY dispatch where the switch is on but the folder is refused quotes why
wt="$pf/repo-wt"
mkdir -p "$wt/.agents/hooks/policy" "$wt/.agents/hooks/lib"
printf 'gitdir: %s/.git/worktrees/wt\n' "$nf" > "$wt/.git"
cp "$ngate" "$wt/.agents/hooks/policy/"; cp "$nf/.agents/hooks/lib/"*.py "$wt/.agents/hooks/lib/"; cp "$nf/.agents/config.json" "$wt/.agents/"
out="$(jq -nc --arg d "$wt" '{project_dir:$d,event:"PreToolUse",session_id:"s3",prompt_id:"p1",tool_name:"Agent",tool_use_id:"tu1",tool_input:{subagent_type:"general-purpose",prompt:"NOTES-ONLY: inventory"}}' |
  env HOME="$home" bash "$wt/.agents/hooks/policy/parallel-writers-gate.sh")"
denied "$out" && [[ "$out" == *"enables the product folder, but the folder is refused"* && "$out" == *"linked worktree"* ]] \
  || fail "a refused product folder was not quoted in the NOTES-ONLY denial ($out)"
printf 'not json' > "$wt/.agents/config.json"
out="$(jq -nc --arg d "$wt" '{project_dir:$d,event:"PreToolUse",session_id:"s3",prompt_id:"p2",tool_name:"Agent",tool_use_id:"tu2",tool_input:{subagent_type:"general-purpose",prompt:"NOTES-ONLY: inventory"}}' |
  env HOME="$home" bash "$wt/.agents/hooks/policy/parallel-writers-gate.sh" 2>/dev/null)"
denied "$out" && [[ "$out" == *"no product folder enabled"* && "$out" == *"unreadable"* ]] || fail "a malformed config.json was not reported as the switch off ($out)"
ok "a NOTES-ONLY denial says whether the switch is off or the folder is refused, and why"

# a demotion makes the turn's writer pending again only while that writer has not started
reset
[[ -z "$(ndispatch p13 general-purpose 'change the module' tuw13)" ]] || fail "writer refused"
[[ -z "$(ndispatch p13 general-purpose 'READ-ONLY: look' tum13)" ]] || fail "READ-ONLY dispatch refused"
meta m13 tum13; nstart m13 general-purpose p13
denied "$(nwrite m13 general-purpose "$pf/notes/x.md")" || fail "a READ-ONLY write passed"
[[ "$(live_lines)" -eq 0 ]] || fail "the marked cell was not demoted"
denied "$(ndispatch p13 general-purpose 'change another module' tuw13b)" || fail "the marked cell's demotion lost the dispatched writer that had not started"
nstart w13 general-purpose p13
denied "$(nlead p13 "$nf/src/x.md")" || fail "the writer that started after the demotion did not register"
reset
[[ -z "$(ndispatch p14 general-purpose 'change the module' tuw14)" ]] || fail "writer refused"
[[ -z "$(ndispatch p14 general-purpose 'READ-ONLY: look' tum14)" ]] || fail "READ-ONLY dispatch refused"
meta m14 tum14; nstart w14 general-purpose p14; nstart m14 general-purpose p14
denied "$(nwrite m14 general-purpose "$pf/notes/x.md")" || fail "a READ-ONLY write passed"
nstop w14 general-purpose
[[ -z "$(ndispatch p14 general-purpose 'change another module' tuw14b)" ]] || fail "a demotion counted a writer pending after it had started and stopped"
ok "a demoted cell leaves its turn's writer pending until it starts, and never after"

# a marked cell that starts first beside its turn's writer: whether the writer
# is live at the marked cell's first write, has already stopped, or the marked
# cell stops without writing, the writer is pending exactly until it starts and
# the turn is clear once both stopped
for order in writer-live writer-stopped never-writes; do
  reset
  [[ -z "$(ndispatch p17 general-purpose 'change the module' tuw17)" ]] || fail "$order: writer refused"
  [[ -z "$(ndispatch p17 general-purpose 'READ-ONLY: look' tum17)" ]] || fail "$order: READ-ONLY dispatch refused"
  meta m17 tum17; meta w17 tuw17
  nstart m17 general-purpose p17
  case "$order" in
    writer-live)
      nstart w17 general-purpose p17
      denied "$(nwrite m17 general-purpose "$pf/notes/x.md")" || fail "$order: a READ-ONLY write passed"
      denied "$(ndispatch p17 general-purpose 'change another module' tuw17b)" || fail "$order: a second writer passed beside the live writer"
      nstop m17 general-purpose; nstop w17 general-purpose ;;
    writer-stopped)
      nstart w17 general-purpose p17; nstop w17 general-purpose
      denied "$(nwrite m17 general-purpose "$pf/notes/x.md")" || fail "$order: a READ-ONLY write passed"
      nstop m17 general-purpose ;;
    never-writes)
      nstop m17 general-purpose
      denied "$(ndispatch p17 general-purpose 'change another module' tuw17b)" || fail "$order: a writer passed while its turn's first writer had not started"
      nstart w17 general-purpose p17; nstop w17 general-purpose ;;
  esac
  [[ -z "$(ndispatch p17 general-purpose 'change another module' tuw17c)" ]] || fail "$order: a writer was refused after every cell of its turn stopped"
done
ok "a marked cell that starts before its turn's writer leaves the writer pending exactly until it starts, in every order"

# demotion happens only under the lock: with the lock busy the write is still denied and the cell stays live
reset
[[ -z "$(ndispatch p15 general-purpose 'READ-ONLY: look' tum15)" ]] || fail "READ-ONLY dispatch refused"
meta m15 tum15; nstart m15 general-purpose p-unrecorded
mkdir "$nf/.agents/.writers-lock-s2"
out="$(nwrite m15 general-purpose "$pf/notes/x.md")"
rmdir "$nf/.agents/.writers-lock-s2"
denied "$out" || fail "a READ-ONLY write passed while the lock was busy"
grep -q '^m15	' "$nlive" && grep -q 'lock is busy' "$scratch/gerr" || fail "a demotion ran without the lock, or skipped it silently"
ok "with the lock busy a marked cell's write is denied and its demotion is skipped aloud"

# many concurrent marked writes beside live writers: every one denied, the writers kept
reset
nstart w16a implementer p-a; nstart w16b mechanic p-b
[[ -z "$(ndispatch p16 general-purpose 'READ-ONLY: look' tum16)" ]] || fail "READ-ONLY dispatch refused"
meta m16 tum16; nstart m16 general-purpose p-c
for i in $(seq 1 24); do (nwrite m16 general-purpose "$pf/notes/x.md" > "$scratch/c16-$i" 2>/dev/null) & done; wait
for i in $(seq 1 24); do denied "$(<"$scratch/c16-$i")" || fail "concurrent READ-ONLY write $i was not denied ('$(<"$scratch/c16-$i")')"; done
grep -q '^w16a	' "$nlive" && grep -q '^w16b	' "$nlive" || fail "concurrent demotions lost a live writer: '$(cat "$nlive")'"
! grep -q '^m16	' "$nlive" || fail "the marked cell stayed live after 24 writes"
ok "24 concurrent READ-ONLY writes are all denied and both live writers stay registered"

# OUTSIDE cells: two in one message pass beside a writer, write their own
# directories, are denied the checkout, and never hold the lead
reset
mkdir -p "$scratch/copy-a" "$scratch/copy-b"
[[ -z "$(ndispatch p20 general-purpose 'change the module' tuw20)" ]] || fail "the writer was refused"
[[ -z "$(ndispatch p20 general-purpose "WORKSPACE: $scratch/copy-a" tuo20a)" ]] || fail "the first outside cell was refused"
[[ -z "$(ndispatch p20 implementer "build the model
WORKSPACE: $scratch/copy-b" tuo20b)" ]] || fail "the second outside cell was refused"
grep -q $'^tuo20a\tOUTSIDE$' "$nf/.agents/.cell-markers-s2" && grep -q $'^tuo20b\tOUTSIDE$' "$nf/.agents/.cell-markers-s2" \
  || fail "the outside dispatches were not recorded: $(cat "$nf/.agents/.cell-markers-s2")"
meta w20 tuw20; meta o20a tuo20a; meta o20b tuo20b
nstart w20 general-purpose p20; nstart o20a general-purpose p20; nstart o20b implementer p20
! grep -q '^o20b	' "$nlive" || fail "an outside cell of a type no writer shares registered as a writer"
[[ -z "$(nwrite o20a general-purpose "$scratch/copy-a/finance.py")" ]] || fail "an outside cell was refused its own directory"
! grep -q '^o20a	' "$nlive" || fail "an outside cell that shared a writer's type stayed live after its first write"
out="$(nwrite o20b implementer "$nf/src/x.py")"
denied "$out" && [[ "$out" == *"dispatched to work outside this checkout"* ]] || fail "an outside cell wrote in the checkout ($out)"
denied "$(nwrite o20a general-purpose "src/y.py")" || fail "an outside cell wrote in the checkout through a relative path"
[[ -z "$(nwrite w20 general-purpose "$nf/src/x.py")" ]] || fail "the one writer was refused the checkout"
denied "$(ndispatch p20 mechanic 'change another module' tuw20b)" || fail "a second writer passed beside the first"
nstop w20 general-purpose
[[ -z "$(nlead p20 "$nf/src/x.py")" ]] || fail "outside cells held the lead's edit"
ok "outside cells pass beside a writer, keep to their directories, and leave the main tree to the lead"

# a lane cell is held to its worktree the same way
reset
printf '{"runs":{"run":{"lanes":{"ui":{"workspace":"%s"}}}}}' "$scratch/copy-a" > "$nf/.agents/.workloop-state.json"
[[ -z "$(ndispatch p21 general-purpose 'WORKLOOP WORKER BRIEF — run/ui' tul21)" ]] || fail "the lane was refused"
meta l21 tul21; nstart l21 general-purpose p21
denied "$(nwrite l21 general-purpose "$nf/src/x.py")" || fail "a lane cell wrote in the checkout"
[[ -z "$(nwrite l21 general-purpose "$scratch/copy-a/x.py")" ]] || fail "a lane cell was refused its worktree"
rm -f "$nf/.agents/.workloop-state.json"
ok "a lane cell writes its worktree and is denied the checkout"

# an explicit READ-ONLY outranks a lane brief: the cell writes nothing, not even in the lane's worktree
reset
printf '{"runs":{"run":{"lanes":{"ui":{"workspace":"%s"}}}}}' "$scratch/lane-ui" > "$nf/.agents/.workloop-state.json"
[[ -z "$(ndispatch p22 general-purpose 'READ-ONLY: review the lane
WORKLOOP REVIEWER BRIEF — run/ui' tur22)" ]] || fail "a READ-ONLY lane review was refused"
meta r22 tur22; nstart r22 general-purpose p22
denied "$(nwrite r22 general-purpose "$scratch/lane-ui/x.py")" || fail "a READ-ONLY prompt carrying a lane brief wrote in the lane's worktree"
rm -f "$nf/.agents/.workloop-state.json"
ok "a READ-ONLY prompt carrying a lane brief writes nothing"

# --- lane worktrees nested in the checkout -------------------------------------
# A real repository with a workloop lane at .agents/worktrees/r/l and a real
# submodule at src/vendor: the nearest Git working tree decides what is the
# checkout's, and a submodule stays the checkout's.
gr="$(cd "$scratch" && pwd -P)/nested"
glane="$gr/.agents/worktrees/r/l"
gtx="$scratch/transcripts4"
mkdir -p "$gr/.agents" "$gr/src"
git init -q "$gr"; printf '.agents/worktrees/\n' > "$gr/.gitignore"
git -C "$gr" add .gitignore; git -C "$gr" -c user.name=t -c user.email=t@t commit -qm root
git -C "$gr" worktree add -q -b r/l "$glane"
git init -q "$scratch/subsrc"; git -C "$scratch/subsrc" -c user.name=t -c user.email=t@t commit -q --allow-empty -m sub
git -C "$gr" -c protocol.file.allow=always submodule add -q "$scratch/subsrc" src/vendor 2>/dev/null
[[ "$(git -C "$gr/src/vendor" rev-parse --show-superproject-working-tree)" == "$gr" ]] || fail "the submodule fixture is not a submodule of $gr"
mkdir -p "$gr/src/fake"; printf 'gitdir: %s/missing\n' "$scratch" > "$gr/src/fake/.git"
git init -q "$gr/.agents/worktrees/foreign"
gfire() {  # key=value ... -> stdout
  local args=(--arg project_dir "$gr" --arg session_id s4 --arg transcript_path "$gtx/main.jsonl") pair
  for pair in "$@"; do args+=(--arg "${pair%%=*}" "${pair#*=}"); done
  jq -nc "${args[@]}" '$ARGS.named
    | .tool_input = ({subagent_type, prompt, file_path} | with_entries(select(.value != null)))
    | del(.subagent_type, .prompt, .file_path)' | bash "$gate" 2>"$scratch/gerr"
}
gdispatch() { gfire event=PreToolUse tool_name=Agent prompt_id="$1" subagent_type="$2" prompt="$3" tool_use_id="$4"; }
gstart() { gfire event=SubagentStart prompt_id="$3" agent_id="$1" agent_type="$2" >/dev/null; }
gwrite() { gfire event=PreToolUse tool_name=Write agent_id="$1" agent_type="$2" file_path="$3"; }
glead() { gfire event=PreToolUse tool_name=Edit prompt_id="$1" file_path="$2"; }
gmeta() { mkdir -p "$gtx/s4/subagents"; printf '{"toolUseId":"%s"}\n' "$2" > "$gtx/s4/subagents/agent-$1.meta.json"; }

[[ -z "$(gdispatch p30 general-purpose 'change the module' tuw30)" ]] || fail "the writer was refused"
gstart w30 general-purpose p30
for target in "$glane/src/x.py" "$glane/new/deep/x.py" "$glane" "$gr/.agents/worktrees/foreign/x.py"; do
  [[ -z "$(glead p30 "$target")" ]] || fail "the lead was refused $target, in a nested lane worktree, beside a writer in the checkout"
done
for target in "$gr/src/x.py" "$gr/.agents/worktrees/r/x.py" "$gr/.agents/worktrees/r/l2/x.py" "$gr/src/vendor/x.py" "$gr/src/fake/x.py" "src/vendor/x.py"; do
  denied "$(glead p30 "$target")" || fail "the lead edited $target beside a writer in the checkout"
done
ok "the lead edits a nested lane or nested foreign repository freely beside a writer; the checkout, its run folder, a submodule and an unreadable .git stay the checkout's"

[[ -z "$(gdispatch p30 general-purpose "WORKSPACE: $scratch/copy-a" tuo30)" ]] || fail "the outside cell was refused"
gmeta o30 tuo30; gstart o30 general-purpose p30
[[ -z "$(gwrite o30 general-purpose "$glane/src/x.py")" ]] || fail "an outside cell was refused a nested lane worktree"
for target in "$gr/src/x.py" "$gr/src/vendor/x.py" "$gr/.agents/worktrees/r/x.py"; do
  denied "$(gwrite o30 general-purpose "$target")" || fail "an outside cell wrote $target, in the checkout"
done
ok "an OUTSIDE cell writes into a nested lane worktree and is denied the checkout proper and its submodule"

printf '{"runs":{"r":{"lanes":{"l":{"workspace":"%s"},"gone":{"workspace":"%s/.agents/worktrees/r/gone"}}}}}' "$glane" "$gr" > "$gr/.agents/.workloop-state.json"
[[ -z "$(gdispatch p30 implementer 'WORKLOOP WORKER BRIEF — r/l' tul30)" ]] || fail "a brief for a nested lane was refused beside a writer"
grep -q $'^tul30\tOUTSIDE$' "$gr/.agents/.cell-markers-s4" || fail "the nested lane's dispatch was not recorded OUTSIDE"
gmeta l30 tul30; gstart l30 implementer p30
[[ -z "$(gwrite l30 implementer "$glane/src/x.py")" ]] || fail "a nested lane cell was refused its worktree"
denied "$(gwrite l30 implementer "$gr/src/x.py")" || fail "a nested lane cell wrote in the checkout"
denied "$(gdispatch p30 mechanic 'WORKLOOP WORKER BRIEF — r/gone' tug30)" || fail "a brief for a lane whose worktree is missing under the checkout exempted a writer"
rm -f "$gr/.agents/.workloop-state.json"
ok "a brief for a lane nested in the checkout passes as OUTSIDE; the cell writes its worktree and is denied the checkout"

for ws in "$glane" "$glane/src" "$gr/src/vendor"; do
  mkdir -p "$ws"
  out="$(gdispatch p30 mechanic "WORKSPACE: $ws" tuws30)"
  denied "$out" && [[ "$out" == *"WORKSPACE line was not accepted"* ]] || fail "WORKSPACE $ws was accepted ($out)"
done
[[ "$(gdispatch p30 mechanic "WORKSPACE: $glane" tuws30b)" == *"worktree or clone of this repository"* ]] || fail "a nested worktree WORKSPACE was not refused as this repository's worktree"
[[ "$(gdispatch p30 mechanic "WORKSPACE: $gr/src/vendor" tuws30c)" == *"lies inside this checkout"* ]] || fail "a submodule WORKSPACE was not refused as inside the checkout"
ok "a WORKSPACE naming a nested worktree of this repository, or a submodule, is refused"

# disabled
printf '{"hooks":{"parallel_writers":{"enabled":false}}}\n' > "$dir/.agents/config.json"
[[ -z "$(dispatch p4 implementer)" && -z "$(dispatch p4 mechanic)" ]] || fail "the toggle did not disable the gate"
ok "the config toggle turns the gate off"

printf '\nall parallel-writers tests passed\n'

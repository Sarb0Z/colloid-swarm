#!/usr/bin/env bash
# Firing tests for the parallel-writers gate: a second writer dispatched while
# another is live is denied unless it carries a workloop brief; readers and
# sequential writers pass.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

dir="$scratch/fixture"
mkdir -p "$dir/.agents/hooks/policy" "$dir/.agents/hooks/lib"
cp "$repo/.agents/hooks/policy/parallel-writers-gate.sh" "$dir/.agents/hooks/policy/"
cp "$repo/.agents/hooks/lib/config.py" "$dir/.agents/hooks/lib/"
printf '{"hooks":{"parallel_writers":{"enabled":true}}}\n' > "$dir/.agents/config.json"
gate="$dir/.agents/hooks/policy/parallel-writers-gate.sh"

dispatch() {  # <prompt_id> <subagent_type> [prompt] -> stdout
  printf '{"project_dir":"%s","event":"PreToolUse","session_id":"s1","prompt_id":"%s","tool_name":"Agent","tool_input":{"subagent_type":"%s","prompt":%s}}' \
    "$dir" "$1" "$2" "$(printf '%s' "${3:-do the thing}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" | bash "$gate"
}
edit() {  # <prompt_id> -> stdout (the lead editing the main tree)
  printf '{"project_dir":"%s","event":"PreToolUse","session_id":"s1","prompt_id":"%s","tool_name":"Edit","tool_input":{"file_path":"src/x.py"}}' "$dir" "$1" | bash "$gate"
}
start() {  # <agent_id> <agent_type> <prompt_id>
  printf '{"project_dir":"%s","event":"SubagentStart","session_id":"s1","prompt_id":"%s","agent_id":"%s","agent_type":"%s"}' "$dir" "$3" "$1" "$2" | bash "$gate"
}
stop() {  # <agent_id> <agent_type>
  printf '{"project_dir":"%s","event":"SubagentStop","session_id":"s1","agent_id":"%s","agent_type":"%s"}' "$dir" "$1" "$2" | bash "$gate"
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

# a workloop brief passes regardless, and is counted
[[ -z "$(dispatch p1 implementer 'WORKLOOP WORKER BRIEF — run/lane
Objective: x')" ]] || fail "a briefed writer was refused"
ok "a writer carrying a workloop brief passes"
: > "$dir/.agents/.writers-turn-s1"
[[ -z "$(dispatch p9 implementer 'WORKLOOP WORKER BRIEF — run/a')" && -z "$(dispatch p9 mechanic 'WORKLOOP WORKER BRIEF — run/b')" ]] || fail "briefed lanes were refused"
denied "$(dispatch p9 implementer)" || fail "an unbriefed writer passed beside briefed lanes in one message"
ok "briefed lanes are counted, so a plain writer beside them is denied"

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

# the lead's own edit while an uncoordinated writer is live is denied; with a
# workloop run active the live writers are lanes and the main tree is free
: > "$dir/.agents/.writers-turn-s1"
[[ -z "$(edit p5)" ]] || fail "an edit with nothing live was refused"
start a5 implementer p5
denied "$(edit p5)" || fail "the lead edited beside a live uncoordinated writer"
printf '{"version":1,"runs":{"r":{"lanes":{"l":{"state":"active"}}}}}' > "$dir/.agents/.workloop-state.json"
[[ -z "$(edit p5)" ]] || fail "the lead was refused while a workloop run was active"
printf '{"version":1,"runs":{"r":{"torn_down":{"at":"x"},"lanes":{"l":{"state":"active"}}}}}' > "$dir/.agents/.workloop-state.json"
denied "$(edit p5)" || fail "a torn-down run still freed the main tree"
rm "$dir/.agents/.workloop-state.json"; stop a5 implementer
[[ -z "$(edit p5)" ]] || fail "an edit after the writer stopped was refused"
ok "the lead's edit is denied beside a live writer unless a workloop run is active"

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

# disabled
printf '{"hooks":{"parallel_writers":{"enabled":false}}}\n' > "$dir/.agents/config.json"
[[ -z "$(dispatch p4 implementer)" && -z "$(dispatch p4 mechanic)" ]] || fail "the toggle did not disable the gate"
ok "the config toggle turns the gate off"

printf '\nall parallel-writers tests passed\n'

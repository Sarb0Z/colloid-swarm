#!/usr/bin/env bash
# Firing tests for the stop-investigate hedge gate. The load-bearing case is the
# split between giving up and asking: AGENTS.md § "Verify with user" mandates
# escalating when the blocker is the user's, and that escalation is
# word-identical to a punt. A recommendation is what tells them apart.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

# The policy resolves its repository from its own location and reads that
# repository's .agents/config.json, which can turn the gate off. Run a copy from
# a sandbox with the gate explicitly on, so these cases assert what the policy
# does rather than how the surrounding repository is configured.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/.agents/hooks/policy" "$scratch/.agents/hooks/lib"
cp "$repo/.agents/hooks/policy/stop-investigate.sh" "$scratch/.agents/hooks/policy/"
cp "$repo"/.agents/hooks/lib/*.py "$repo"/.agents/hooks/lib/*.sh "$scratch/.agents/hooks/lib/"
printf '{"hooks":{"stop_investigate":{"enabled":true,"ratchet_check":true}}}\n' \
  > "$scratch/.agents/config.json"
policy="$scratch/.agents/hooks/policy/stop-investigate.sh"

say() {  # <message> -> sets rc
  set +e
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps({"last_assistant_message": sys.stdin.read(), "stop_hook_active": False}))' \
    | bash "$policy" >/dev/null 2>&1
  rc=$?
  set -e
}

blocks() { say "$1"; [[ $rc -eq 2 ]] || fail "must block: $1"; }
passes() { say "$1"; [[ $rc -eq 0 ]] || fail "must pass: $1"; }

# Giving up on capability, scope, or ownership. Never legitimate, never disarmed.
blocks "I am unable to determine which config the loader reads."
blocks "That is beyond the scope of this change."
blocks "You'll need to verify the staging credentials yourself."
blocks "I'll stop here."
ok    "capability, scope and ownership give-ups block"

# A recommendation does not buy a give-up. Stopping is still stopping.
blocks "I'll stop here. I recommend raising the timeout to 30s."
blocks "This is out of scope for the current task, though I'd recommend fixing it next."
ok    "a recommendation does not disarm a give-up"

# A bare question is a punt: it asks and stops.
blocks "Could you clarify which of the two schemas is authoritative?"
blocks "Please confirm whether the migration should run before or after the deploy."
blocks "Without more information about the target environment I cannot proceed."
ok    "a bare question blocks"

# The same question carrying a recommendation is the mandated escalation.
passes "Both schemas parse and only you know which is authoritative. Could you confirm which one? I recommend the v2 schema: it is the one the client generator already targets, at the cost of a one-time backfill."
passes "The deploy order is yours to call. My recommendation is to run the migration first, since the new column is read on boot."
passes "I would need access to the staging database to verify the index. I suggest we ship behind the flag and measure there."
ok    "a question carrying a recommendation passes"

# A recommendation aimed at the user is the punt wearing the disarm: it carries
# nothing and hands the investigation back. It must not clear the gate.
blocks "Could you clarify which schema is authoritative? I suggest you check the migration files."
blocks "Please confirm whether to run the migration. I suggest you ask the platform team."
blocks "Could you specify the target? I recommend you look at the deploy logs."
blocks "Without more context I cannot proceed — I'd recommend that you check with the platform team."
ok    "a recommendation aimed at the user does not disarm"

# Ordinary completed work is untouched by either class.
passes "Raised the engines floor to >=22.0.0 in both servers and re-ran the bundle check; both pass."
ok    "an ordinary report passes"

# The provenance ratchet. The verb form counts: a punt that says "six fail"
# never uses the noun "failures".
blocks "All six fail identically without my changes, so they are pre-existing. Committing the code exchange fix with its tests and pushing for the deploy."
blocks "Those four lint errors are pre-existing, so I left them alone."
passes "Those four lint errors were pre-existing; filed them in .agents/breadcrumbs.md and moved on."
ok    "a provenance claim beside a defect blocks unless it is filed"

# The ratchet reads the whole turn, not the last message. A long turn buries
# the claim under later work; the final message is about something else.
transcript() {  # <rows...> -> writes $scratch/transcript.jsonl
  : > "$scratch/transcript.jsonl"
  for row in "$@"; do printf '%s\n' "$row" >> "$scratch/transcript.jsonl"; done
}
user_row()      { printf '{"type":"user","message":{"role":"user","content":%s}}' "$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"; }
result_row()    { printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'; }
assistant_row() { printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":%s}]}}' "$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"; }

say_turn() {  # <last message> -> sets rc, using $scratch/transcript.jsonl
  set +e
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps({"last_assistant_message": sys.stdin.read(), "transcript_path": sys.argv[1], "stop_hook_active": False}))' "$scratch/transcript.jsonl" \
    | bash "$policy" >"$scratch/out" 2>"$scratch/err"
  rc=$?
  set -e
}

final="Now the intersection: which of those fifty routines the API role cannot execute on staging."
transcript "$(user_row 'continue please')" \
  "$(assistant_row 'All six fail identically without my changes, so they are pre-existing. Committing and pushing for the deploy.')" \
  "$(result_row)" \
  "$(assistant_row "$final")"
say_turn "$final"
[[ $rc -eq 2 ]] || fail "a mid-turn provenance punt must block at Stop"
grep -q "fail identically without my changes, so they are pre-existing" "$scratch/err" \
  || fail "the block reason must quote the span that fired: $(cat "$scratch/err")"
ok    "a mid-turn provenance punt blocks and is quoted"

# The same claim in an earlier turn is history, not this turn's punt.
transcript "$(user_row 'run the suite')" \
  "$(assistant_row 'All six fail identically without my changes, so they are pre-existing.')" \
  "$(user_row 'ok, fix them')" \
  "$(assistant_row 'Fixed all six; the suite is green.')"
say_turn "Fixed all six; the suite is green."
[[ $rc -eq 0 ]] || fail "a claim in a previous turn must not block: $(cat "$scratch/err")"
ok    "a previous turn's claim does not block"

# A filing before the claim was about something else and must not disarm it.
transcript "$(user_row 'continue please')" \
  "$(assistant_row 'Filed the flaky retry in .agents/breadcrumbs.md and moved on.')" \
  "$(result_row)" \
  "$(assistant_row 'All six fail identically without my changes, so they are pre-existing. Committing and pushing.')"
say_turn "All six fail identically without my changes, so they are pre-existing. Committing and pushing."
[[ $rc -eq 2 ]] || fail "an earlier unrelated filing must not disarm a later punt"
ok    "an earlier filing about something else does not disarm"

# A filing later in the same turn disarms a claim made earlier in it.
transcript "$(user_row 'continue please')" \
  "$(assistant_row 'Those four lint errors are pre-existing.')" \
  "$(result_row)" \
  "$(assistant_row 'Filed the four lint errors in .agents/breadcrumbs.md; the change itself is green.')"
say_turn "Filed the four lint errors in .agents/breadcrumbs.md; the change itself is green."
[[ $rc -eq 0 ]] || fail "a filing later in the turn must disarm: $(cat "$scratch/err")"
ok    "a filing later in the turn disarms"

printf '\nALL PASS\n'

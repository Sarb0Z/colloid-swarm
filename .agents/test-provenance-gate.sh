#!/usr/bin/env bash
# Firing tests for the provenance gate: the PreToolUse policy that denies the
# next tool call after a turn ties "pre-existing" to a defect it is not fixing.
# The load-bearing cases are the moment (mid-turn, before the call that ships)
# and the once-per-claim ledger: the model is told once, answers, and moves on.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

# A sandbox copy with the gate on, so the cases assert the policy and not the
# surrounding repository's config.json. The ledger lands in the sandbox too.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/.agents/hooks/policy" "$scratch/.agents/hooks/lib" "$scratch/.agents/claude"
cp "$repo/.agents/hooks/policy/provenance-gate.sh" "$scratch/.agents/hooks/policy/"
cp "$repo"/.agents/hooks/lib/*.py "$repo"/.agents/hooks/lib/*.sh "$scratch/.agents/hooks/lib/"
cp "$repo/.agents/claude/adapter.sh" "$repo/.agents/claude/normalize-hook.py" "$scratch/.agents/claude/"
printf '{"hooks":{"provenance_gate":{"enabled":true}}}\n' > "$scratch/.agents/config.json"
policy="$scratch/.agents/hooks/policy/provenance-gate.sh"
transcript="$scratch/transcript.jsonl"

seq=0
row() {  # <role> <content-json>; every row gets its own uuid, as the host writes
  seq=$((seq + 1))
  printf '{"type":"%s","uuid":"row-%d","message":{"role":"%s","content":%s}}\n' "$1" "$seq" "$1" "$2"
}
text() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }
user()      { row user "$(text "$1")"; }
assistant() { row assistant "[{\"type\":\"text\",\"text\":$(text "$1")}]"; }
result()    { row user '[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]'; }

run() {  # -> sets rc, out
  set +e
  out="$(printf '{"transcript_path":"%s","session_id":"s1"}' "$transcript" | bash "$policy" 2>"$scratch/err")"
  rc=$?
  set -e
}
denies() { run; [[ $rc -eq 0 ]] && grep -q '"permissionDecision": "deny"' <<<"$out" || fail "must deny: $1 ($(cat "$scratch/err"))"; }
quiet()  { run; [[ $rc -eq 0 && -z "$out" ]] || fail "must be quiet: $1 (got: $out)"; }

# The clearclaim sentence, followed by the call that would have shipped it.
{ user "continue please"
  assistant "All six fail identically without my changes, so they are pre-existing. Committing the code exchange fix with its tests and pushing for the deploy."
} > "$transcript"
denies "the punt before the commit-and-push"
grep -q "Before this tool call runs" <<<"$out" || fail "the reason must name the moment"
grep -q "fail identically without my changes, so they are pre-existing" <<<"$out" || fail "the reason must quote the claim"
ok    "a provenance punt denies the next tool call and quotes itself"

# Told once. The same claim does not deny the calls that answer it.
quiet "the same claim on the following call"
ok    "a reported claim is quiet on the next call"

# A new claim in the same turn is a new report.
{ result; assistant "Also, the two lint warnings are pre-existing."; } >> "$transcript"
denies "a second, different claim"
quiet "the second claim on the following call"
ok    "each claim is reported once"

# The turn keeps growing after the claim. The greedy window can then match a
# longer span for the same claim; it must still count as reported once.
{ user "continue please"
  assistant "Those lint errors are pre-existing."
} > "$transcript"
denies "the claim as first seen"
{ result; assistant "Moving on: this other bug is in the parser."; } >> "$transcript"
quiet "the same claim after the turn grew past it"
ok    "a claim stays reported once as the turn grows"

# Rows the host writes under the user role do not end the turn: Stop-hook
# feedback and skill preambles carry isMeta. The punt before them still fires.
{ user "continue please"
  assistant "The two typecheck errors were already failing before my change."
  result
  row user '"Stop hook feedback: uncommitted changes"' | sed 's/^{/{"isMeta":true,/'
  assistant "Carrying on."
} > "$transcript"
denies "a punt behind a host-synthesized user row"
ok    "a host-synthesized user row does not end the turn"

# A filing before the punt was about something else; it must not disarm.
{ user "continue please"
  assistant "Filed the flaky retry in .agents/breadcrumbs.md and moved on."
  result
  assistant "All six fail identically without my changes, so they are pre-existing. Committing and pushing for the deploy."
} > "$transcript"
denies "a punt after an unrelated filing"
ok    "an earlier filing about something else does not disarm"

# A provenance word ending one message and a defect word opening the next are
# not one sentence.
{ user "continue please"
  assistant "The retry path is pre-existing."
  result
  assistant "Six tests fail."
} > "$transcript"
quiet "a window spanning two messages"
ok    "the window does not cross a message boundary"

# The same sentence in a later turn is a new punt, reported again.
{ user "run the suite"
  assistant "Those typecheck errors were already failing before my change."
} > "$transcript"
denies "a punt in turn one"
{ user "ok, fix them"; assistant "Those typecheck errors were already failing before my change."; } >> "$transcript"
denies "the same punt in turn two"
ok    "a repeated punt in a later turn is reported again"

# A filing disarms: the turn names where the work went.
{ user "next task"
  assistant "Those four lint errors are pre-existing; filed them in .agents/breadcrumbs.md and moving on."
} > "$transcript"
quiet "a filed claim"
ok    "a filing disarms the gate"

# A previous turn's claim is history.
{ user "run the suite"
  assistant "All six fail identically without my changes, so they are pre-existing."
  user "ok, fix them"
  assistant "Fixing all six now."
} > "$transcript"
quiet "a claim in a previous turn"
ok    "a previous turn's claim does not fire"

# Ordinary work, and no transcript at all, stay quiet.
{ user "add the flag"; assistant "Added the flag and its test; both pass."; } > "$transcript"
quiet "ordinary work"
rm -f "$transcript"
quiet "no transcript"
ok    "clean turns and missing transcripts are quiet"

# The config toggle turns it off.
{ user "continue"; assistant "Those errors are pre-existing."; } > "$transcript"
printf '{"hooks":{"provenance_gate":{"enabled":false}}}\n' > "$scratch/.agents/config.json"
quiet "the gate toggled off"
ok    "the config toggle turns the gate off"
printf '{"hooks":{"provenance_gate":{"enabled":true}}}\n' > "$scratch/.agents/config.json"

# The wired Claude path: the host payload names the transcript at the top
# level, the adapter scopes to the main agent, and a subagent is left alone.
rm -f "$scratch"/.agents/.provenance-*
claude_payload() {  # <extra-json-fields>
  printf '{"session_id":"s2","hook_event_name":"PreToolUse","cwd":"%s","transcript_path":"%s","tool_name":"Bash","tool_input":{"command":"git commit -m x && git push"}%s}' "$scratch" "$transcript" "$1"
}
out="$(claude_payload "" | CLAUDE_PROJECT_DIR="$scratch" bash "$scratch/.agents/claude/adapter.sh" --agent main provenance-gate.sh)"
grep -q '"permissionDecision": "deny"' <<<"$out" || fail "the wired Claude path must deny: $out"
out="$(claude_payload ',"agent_id":"a1","agent_type":"implementer"' | CLAUDE_PROJECT_DIR="$scratch" bash "$scratch/.agents/claude/adapter.sh" --agent main provenance-gate.sh)"
[[ -z "$out" ]] || fail "a subagent must not be gated by the main-agent hook: $out"
ok    "the wired Claude adapter path denies for the main agent only"

printf '\nALL PASS\n'

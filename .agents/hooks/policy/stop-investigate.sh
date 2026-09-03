#!/usr/bin/env bash
# Engine-agnostic policy: block end-of-turn when the last assistant
# message hedges, declares the task out of scope, or disclaims ownership
# of code it touched.
#
# Input  (stdin JSON): {"last_assistant_message": "...", "transcript_path": "...", "stop_hook_active": bool}
# Output: exit 2 + stderr reason on a match; exit 0 otherwise.
#
# Two pattern classes share one hook because their reasons must not interleave
# on stderr. They are otherwise distinct: hedging is about capability
# ("I can't"), disclaiming is about ownership ("not mine"). Hedges are checked
# first — a give-up is the harder failure — so a turn doing both shows only
# the hedge reason.
#
# They read different text. A hedge is a way of ending, so it is judged on the
# last message alone: a mid-turn question the model then answered itself is
# not a punt. A provenance claim is a way of moving on, so it is judged on the
# whole turn: "those six are pre-existing" lands in the middle of a long turn,
# the model pushes and carries on, and the final message is about something
# else entirely. Read from the transcript when the host names one; fall back
# to the host-provided last message otherwise.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
cfg_path="$repo/.agents/config.json"
toggles="$(python3 "$lib/config.py" "$cfg_path" \
  hooks.stop_investigate.enabled=true hooks.stop_investigate.ratchet_check=true)"
enabled="$(printf '%s\n' "$toggles" | sed -n '1p')"
ratchet="$(printf '%s\n' "$toggles" | sed -n '2p')"
[[ "$enabled" == "no" ]] && exit 0

# One interpreter for all three fields. The message goes last because it is the
# one field that may span lines.
parsed="$(python3 "$lib/payload.py" stop_hook_active=false transcript_path last_assistant_message)"
stop_active="$(printf '%s\n' "$parsed" | sed -n '1p')"
transcript="$(printf '%s\n' "$parsed" | sed -n '2p')"
last_msg="$(printf '%s\n' "$parsed" | tail -n +3)"

[[ "$stop_active" == "yes" ]] && exit 0
if [[ -z "$last_msg" && -n "$transcript" && -f "$transcript" ]]; then
  last_msg="$(python3 "$lib/last-message.py" "$transcript")"
fi

[[ -z "$last_msg" ]] && exit 0

# Two hedge classes, because only one of them can be legitimate. Giving up on
# capability, scope, or ownership never is. Asking the user a question is
# MANDATED by AGENTS.md § "Verify with user" when the blocker is genuinely
# theirs — and a mandated escalation is word-identical to a punt, so blocking
# every question-shaped sentence bans the behavior the rules require and leaves
# AskUserQuestion as the only legal way to ask.
gives_up='(\b(I.?m|I am) unable to\b|\bcannot determine (without|whether|if)\b|\bunable to (verify|determine|confirm) without\b|\b(don.?t|do not) have (enough|sufficient) (context|information)\b|\b(I.?ll|I will) stop here\b|\bbeyond the scope of\b|\bout of scope for (this|the current)\b|\bleaving (this|that) (for|to) you\b|\byou.?ll need to (check|verify|investigate|determine|decide)\b)'
asks='(\bwould need (more )?(information|context|access) (to|from)\b|\bcould you (clarify|confirm|provide|specify|tell me)\b|\bplease (let me know|clarify|confirm|specify) (which|what|whether|if)\b|\bwithout more (information|context|details)\b)'
# The disarm, on the same principle as the ratchet disarm below: a deliberate,
# legible act clears the gate. AGENTS.md requires an escalation to carry "your
# recommendation with its trade-offs", so a recommendation is exactly what a
# punt lacks — it asks and stops where an escalation asks and says what it would
# do. Nothing disarms `gives_up`: a recommendation attached to "I'll stop here"
# is still stopping.
escalation='(\b(I|we) recommend\b|\bI.?d recommend\b|\bmy recommendation\b|\brecommend(ed|ation):|\bI suggest\b)'
# `handback` takes the disarm back, the way `unfiled` does for the ratchet: a
# recommendation aimed AT the user is the punt wearing the disarm. "I suggest you
# check the logs" carries nothing and returns the investigation, where "I suggest
# we take v2" commits to an answer. ERE has no lookahead, so the exclusion is its
# own pattern rather than a negated group.
handback='\b(recommend|suggest)(s|ing|ed)? (that )?you\b'

escalated="no"
if printf '%s' "$last_msg" | grep -Eqi "$escalation" \
   && ! printf '%s' "$last_msg" | grep -Eqi "$handback"; then
  escalated="yes"
fi

if printf '%s' "$last_msg" | grep -Eqi "$gives_up" \
   || { [[ "$escalated" == "no" ]] && printf '%s' "$last_msg" | grep -Eqi "$asks"; }; then
  cat >&2 <<'EOF'
Your last message hedged, asked the user to do investigation, or declared
the task out of scope. Re-read the principles: investigate, then act.
Read the referenced files, trace the code path, run the read-only
commands you have access to, and reach a defensible conclusion. Escalate
to the user only when a decision genuinely requires information or
authority they alone hold. Continue the work now.

If this IS that escalation, it is missing what makes it one. Carry what you
found, the options, and your recommendation with its trade-offs, so the user
can decide in one reply rather than asking you what you would do.
EOF
  exit 2
fi

[[ "$ratchet" == "no" ]] && exit 0

turn_msg="$last_msg"
if [[ -n "$transcript" && -f "$transcript" ]]; then
  turn_msg="$(python3 "$lib/turn-text.py" "$transcript")"
  [[ -n "$turn_msg" ]] || turn_msg="$last_msg"
fi

# The rule and the reason live in ../lib/ratchet-claim.sh and
# ../lib/ratchet-reason.sh, shared with the PreToolUse gate that catches the
# same claim before the next tool call. This is the second layer: a claim made
# after the last tool call, or one the model was already told about and shipped
# anyway, still blocks the turn from ending.
claim="$(printf '%s' "$turn_msg" | bash "$lib/ratchet-claim.sh" | head -n 1)"
if [[ -n "$claim" ]]; then
  bash "$lib/ratchet-reason.sh" "$claim" >&2
  exit 2
fi

exit 0

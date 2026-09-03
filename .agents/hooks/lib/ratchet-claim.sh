#!/usr/bin/env bash
# The provenance ratchet: find a claim that ties "not mine" to a defect the
# message is not fixing.
#
# Input  (stdin): assistant prose — one message, or a whole turn with messages
#                 separated by a line holding only U+001E (turn-text.py's form).
# Output (stdout): every span that fired, one per line, in text order; nothing
#                  when the text is clean or a filing disarms it. Exit 0 always.
#
# Each message is judged on its own, and a filing disarms a claim only when it
# sits in the same message or a later one. Read over the whole turn at once,
# a breadcrumb filed early about something else voided every claim after it,
# and a provenance word at the end of one message met a defect word at the
# start of the next inside one window. Clean turns cost one grep: the windowed
# scan runs only on a message that names provenance at all.
#
# ratchet-reason.sh prints the block reason for a span. The two live together
# so that the Stop gate and the PreToolUse gate judge one sentence by one rule
# and answer it in one voice.
#
# Two substrates, because the triggers and the disarm want opposite treatment of
# markdown quoting. ratchet-text.py states which and why.
#
# Two-key gate, deliberately AGGRESSIVE. Provenance must sit within NEAR chars of
# a second key — either an explicit declination ("so I left it alone") or a plain
# DEFECT word ("those lint errors are pre-existing"). The defect key exists because
# the natural punt never announces itself: it states provenance about a failure it
# just surfaced and moves on, and an announced-punts-only gate misses it entirely.
#
# The cost is knowingly accepted: "those tests are pre-existing" is word-identical
# whether it dodges work or answers "did you break this?" — only intent separates
# them, and intent is not in the text. So the gate fires on the claim and the
# REASON tells the model to say so in one line when it misread. The model has the
# context the regex cannot: it knows whether the user asked.
#
# Proximity still bounds it — a punt is one claim in one sentence (~40 chars
# between keys). Without it this fired on a report saying "a pre-existing failure
# was correctly suppressed" in one paragraph and "Left alone, every edit would drop
# a file" (a conditional, not a declination) 233 chars later. A sanctioned
# disposition (breadcrumb, debt-log entry) still clears it: that is the policy
# working, not a dodge.
#
# The triggers read `prose`; the disarm reads `ledger`. The disarm must not
# out-permission the triggers: matched against the raw message, naming a ledger
# inside a fenced block would void the whole check.

set -euo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEP=$'\x1e'

provenance='(\b(pre-?existing|long-?standing)\b|\bnot (introduced|caused|added) by (this|my|the current) (change|edit|diff|pr|patch|work)\b|\b(was|were|is|are) already (broken|failing|wrong)\b|\bnot (my|mine|this change.?s) (code|work|bug|problem|mess)\b|\bI (didn.?t|did not) (write|introduce|add|author) (this|that|it|the)\b|\bunrelated to (this|my|the current) (change|diff|edit|pr|patch|work|task)\b|\bnot part of (this|my) (change|diff|edit|pr|patch|task)\b|\b(an|a) (existing|upstream|legacy) (issue|bug|problem|failure)\b|\b(existed|was there) (before|prior to)\b|\bpre-?dates\b)'
declines='(\bleav(e|ing) (it |that |them |those |this )?(alone|as.?is|be|for now|untouched)\b|\bleft (it |that |them |those |this )?(alone|as.?is|untouched|for now)\b|\b(not|won.?t|will not|do not|don.?t) (fix|fixing|address|addressing|touch|touching|change|changing) (it|that|them|those|this)\b|\b(didn.?t|did not) (fix|address|touch) (it|that|them|those|this)\b|\bout of scope\b|\bnot in scope\b|\bnot worth fixing\b|\b(so|and) I (skipped|ignored) (it|that|them|those)\b|\bskipping (it|that|them|those)\b|\b(untouched|unaffected|not touched) by (my|this|the|these) (change|changes|diff|edit|edits|work|pr|patch)\b)'
# A defect the message is reporting. Provenance next to one is the silent punt —
# "those 4 lint errors are pre-existing" declines nothing out loud but fixes
# nothing either. Deliberately catches some honest answers; the reason handles it.
# The verb forms are here because the punt counts as often as it names: "all
# six fail identically without my changes" reports six failures without ever
# using the noun.
defects='\b(error|errors|fail|fails|failed|failure|failures|failing|warning|warnings|bug|bugs|breakage|regression|violation|violations|lint|typecheck|type-check)\b'
# The disarm needs an affirmative filing VERB next to the ledger, not a bare
# mention: a turn that merely cites breadcrumbs.md while punting elsewhere must
# still block. `unfiled` then takes back the negated form ("not filing it to
# debt-log.md"), which otherwise disarms by naming the thing it refuses to do.
# The gap is `.{0,120}`, not a bracket class: POSIX ERE does not read `\n` inside
# brackets, so `[^\n]` means "not a backslash and not the letter n" and silently
# never matches an ordinary sentence. `ledger` is already newline-flattened, so
# `.` reaches across a bulleted filing.
#
# `unfiled` carries the SAME ledger proximity as `filed`. Unscoped, any negation
# anywhere in the message re-armed the block — "there's no need to file a
# changelog entry" three sentences away from a genuine filing blocked correct
# work. The negation only counts when it is negating THIS filing.
ledger_f='(breadcrumbs\.md|debt-log\.md)'
filed="(\\b(filed|filing|recorded|recording|logged|logging|noted|noting|tracked|tracking|captured|added)\\b.{0,120}$ledger_f|\\bdebt: ?[a-z0-9-]+)"
unfiled="\\b(not|never|without|no need to)\\s+(going to\\s+|gonna\\s+)?(fil(e|ing)|record(ing)?|logg?(ing)?|track(ing)?|not(e|ing))\\b.{0,120}$ledger_f"
NEAR=140   # generous for one sentence, well under the 233 that misfired
key2="($declines|$defects)"

input="$(cat)"
printf '%s' "$input" | grep -Eqi "$provenance" || exit 0

# Split on the separator line into an array of messages.
messages=()
current=""
while IFS= read -r line; do
  if [[ "$line" == "$SEP" ]]; then
    messages+=("$current"); current=""
  else
    current+="$line"$'\n'
  fi
done <<<"$input"
messages+=("$current")
count=${#messages[@]}

for ((i = 0; i < count; i++)); do
  message="${messages[$i]}"
  printf '%s' "$message" | grep -Eqi "$provenance" || continue
  both="$(printf '%s' "$message" | python3 "$lib/ratchet-text.py")"
  prose="${both%%---RATCHET-SPLIT---*}"
  # Flattened so the proximity window can span a line break inside one
  # sentence; grep is line-based, so `.` cannot cross a newline otherwise.
  prose_flat="$(printf '%s' "$prose" | tr '\n' ' ')"
  spans="$(printf '%s' "$prose_flat" | grep -Eoi "$provenance.{0,$NEAR}$key2|$key2.{0,$NEAR}$provenance" || true)"
  [[ -n "$spans" ]] || continue
  # The disarm reads this message and everything after it, on the ledger
  # substrate: a filing that precedes the claim was about something else.
  rest="$(printf '%s\n' "${messages[@]:$i}")"
  ledger="$(printf '%s' "$rest" | python3 "$lib/ratchet-text.py")"
  ledger="${ledger##*---RATCHET-SPLIT---}"
  if printf '%s' "$ledger" | grep -Eqi "$filed" \
     && ! printf '%s' "$ledger" | grep -Eqi "$unfiled"; then
    continue
  fi
  printf '%s\n' "$spans"
done
exit 0

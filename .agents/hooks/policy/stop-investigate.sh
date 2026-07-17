#!/usr/bin/env bash
# Engine-agnostic policy: block end-of-turn when the last assistant
# message hedges, declares the task out of scope, or disclaims ownership
# of code it touched.
#
# Input  (stdin JSON): {"transcript_path": "...", "stop_hook_active": bool}
# Output: exit 2 + stderr reason on a match; exit 0 otherwise.
#
# Two pattern classes share one hook because a second Stop hook would race
# this one's stderr. They are otherwise distinct: hedging is about capability
# ("I can't"), disclaiming is about ownership ("not mine"). Hedges are checked
# first — a give-up is the harder failure — so a message doing both shows only
# the hedge reason.
#
# Only wired where the host engine exposes a transcript path (Claude
# Code today). Silent no-op if transcript_path is missing.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cfg_path="$repo/.agents/config.json"
toggles="$(CFG_PATH="$cfg_path" python3 <<'PY'
import json, os
cfg = {}
try:
    with open(os.environ["CFG_PATH"], encoding="utf-8") as f: cfg = json.load(f)
except Exception: pass
h = cfg.get("hooks", {}).get("stop_investigate", {})
print("yes" if h.get("enabled", True) else "no")
print("yes" if h.get("ratchet_check", True) else "no")
PY
)"
enabled="$(printf '%s\n' "$toggles" | sed -n '1p')"
ratchet="$(printf '%s\n' "$toggles" | sed -n '2p')"
[[ "$enabled" == "no" ]] && exit 0

input="$(cat)"

parsed="$(HOOK_INPUT="$input" python3 <<'PY'
import json, os
d = json.loads(os.environ["HOOK_INPUT"] or "{}")
print(str(d.get("stop_hook_active", False)).lower())
print(d.get("transcript_path", ""))
PY
)"
stop_active="$(printf '%s\n' "$parsed" | sed -n '1p')"
transcript="$(printf '%s\n' "$parsed" | sed -n '2p')"

[[ "${stop_active:-false}" == "true" ]] && exit 0
[[ -z "${transcript:-}" || ! -f "$transcript" ]] && exit 0

last_msg="$(python3 - "$transcript" <<'PY'
import json, sys
path = sys.argv[1]
last = ""
with open(path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        msg = row.get("message") or {}
        if msg.get("role") != "assistant":
            continue
        content = msg.get("content")
        if isinstance(content, str):
            last = content
        elif isinstance(content, list):
            parts = [b.get("text", "") for b in content
                     if isinstance(b, dict) and b.get("type") == "text"]
            last = "\n".join(parts)
print(last)
PY
)"

[[ -z "$last_msg" ]] && exit 0

hedges='(\b(I.?m|I am) unable to\b|\bcannot determine (without|whether|if)\b|\bunable to (verify|determine|confirm) without\b|\b(don.?t|do not) have (enough|sufficient) (context|information)\b|\bwould need (more )?(information|context|access) (to|from)\b|\bcould you (clarify|confirm|provide|specify|tell me)\b|\bplease (let me know|clarify|confirm|specify) (which|what|whether|if)\b|\bwithout more (information|context|details)\b|\b(I.?ll|I will) stop here\b|\bbeyond the scope of\b|\bout of scope for (this|the current)\b|\bleaving (this|that) (for|to) you\b|\byou.?ll need to (check|verify|investigate|determine|decide)\b)'

if printf '%s' "$last_msg" | grep -Eqi "$hedges"; then
  cat >&2 <<'EOF'
Your last message hedged, asked the user to do investigation, or declared
the task out of scope. Re-read the principles: investigate, then act —
never speculate, never give up before using the tools. Read the
referenced files, trace the code path, run the read-only commands you
have access to, and reach a defensible conclusion. Escalate to the user
only when a decision genuinely requires information or authority they
alone hold. Continue the work now.
EOF
  exit 2
fi

[[ "$ratchet" == "no" ]] && exit 0

# Two substrates, because the triggers and the disarm want opposite treatment of
# markdown quoting. Both drop fenced blocks and blockquotes — bulk citation is
# never a claim either way.
#
#   prose  (triggers) — inline code and quoted spans BLANKED. Quoting a banned
#           phrase must not read as making it.
#   ledger (disarm)   — the same spans UNWRAPPED, and whitespace flattened. A
#           path is conventionally written `.agents/debt-log.md`; blanking inline
#           code would delete the very evidence the disarm looks for, so a correct
#           filing would block — and the block message asks the agent to name
#           where it filed, so it would comply, backtick the path, and block
#           again. Flattening lets the proximity check span a bulleted filing.
#
# Single quotes are deliberately NOT delimiters in either: apostrophes would make
# the check contraction-dependent, eating the span between "it's" and "I've".
both="$(LAST_MSG="$last_msg" python3 <<'PY'
import os, re
t = os.environ["LAST_MSG"]
t = re.sub(r"```.*?```", " ", t, flags=re.S)
t = re.sub(r"(?m)^\s*>.*$", " ", t)
prose = re.sub(r"`[^`\n]*`", " ", t)
prose = re.sub(r"\"[^\"\n]*\"|“[^”\n]*”", " ", prose)
ledger = re.sub(r"\s+", " ", re.sub(r"[`\"“”]", " ", t))
print(prose)
print("<<<RATCHET-SPLIT>>>")
print(ledger)
PY
)"
prose="${both%%<<<RATCHET-SPLIT>>>*}"
ledger="${both##*<<<RATCHET-SPLIT>>>}"

# Two-key gate, deliberately AGGRESSIVE. Provenance must sit within NEAR chars of
# a second key — either an explicit declination ("so I left it alone") or a plain
# DEFECT noun ("those lint errors are pre-existing"). The defect key exists because
# the natural punt never announces itself: it states provenance about a failure it
# just surfaced and moves on, and an announced-punts-only gate misses it entirely.
#
# The cost is knowingly accepted: "those tests are pre-existing" is word-identical
# whether it dodges work or answers "did you break this?" — only intent separates
# them, and intent is not in the text. So the gate fires on the claim and the
# REASON tells the model to say so in one line and stop when it misread. The model
# has the context the regex cannot: it knows whether the user asked.
#
# Proximity still bounds it — a punt is one claim in one sentence (~40 chars
# between keys). Without it this fired on a report saying "a pre-existing failure
# was correctly suppressed" in one paragraph and "Left alone, every edit would drop
# a file" (a conditional, not a declination) 233 chars later. A sanctioned
# disposition (breadcrumb, debt-log entry) still clears it: that is the policy
# working, not a dodge.
#
# The triggers read `prose`; the disarm reads `ledger` (see above). The disarm
# must not out-permission the triggers: matched against the raw message, naming a
# ledger inside a fenced block would void the whole check.
provenance='(\b(pre-?existing|long-?standing)\b|\bnot (introduced|caused|added) by (this|my|the current) (change|edit|diff|pr|patch|work)\b|\b(was|were|is|are) already (broken|failing|wrong)\b|\bnot (my|mine|this change.?s) (code|work|bug|problem|mess)\b|\bI (didn.?t|did not) (write|introduce|add|author) (this|that|it|the)\b|\bunrelated to (this|my|the current) (change|diff|edit|pr|patch|work|task)\b|\bnot part of (this|my) (change|diff|edit|pr|patch|task)\b|\b(an|a) (existing|upstream|legacy) (issue|bug|problem|failure)\b|\b(existed|was there) (before|prior to)\b|\bpre-?dates\b)'
declines='(\bleav(e|ing) (it |that |them |those |this )?(alone|as.?is|be|for now|untouched)\b|\bleft (it |that |them |those |this )?(alone|as.?is|untouched|for now)\b|\b(not|won.?t|will not|do not|don.?t) (fix|fixing|address|addressing|touch|touching|change|changing) (it|that|them|those|this)\b|\b(didn.?t|did not) (fix|address|touch) (it|that|them|those|this)\b|\bout of scope\b|\bnot in scope\b|\bnot worth fixing\b|\b(so|and) I (skipped|ignored) (it|that|them|those)\b|\bskipping (it|that|them|those)\b|\b(untouched|unaffected|not touched) by (my|this|the|these) (change|changes|diff|edit|edits|work|pr|patch)\b)'
# A defect the message is reporting. Provenance next to one is the silent punt —
# "those 4 lint errors are pre-existing" declines nothing out loud but fixes
# nothing either. Deliberately catches some honest answers; the reason handles it.
defects='\b(error|errors|failure|failures|failing|warning|warnings|bug|bugs|breakage|regression|violation|violations|lint|typecheck|type-check)\b'
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

disarmed="no"
if printf '%s' "$ledger" | grep -Eqi "$filed" \
   && ! printf '%s' "$ledger" | grep -Eqi "$unfiled"; then
  disarmed="yes"
fi

# Flattened so the proximity window can span a line break inside one sentence;
# grep is line-based, so `.` cannot cross a newline otherwise.
prose_flat="$(printf '%s' "$prose" | tr '\n' ' ')"
NEAR=140   # generous for one sentence, well under the 233 that misfired

key2="($declines|$defects)"
if printf '%s' "$prose_flat" | grep -Eqi "$provenance.{0,$NEAR}$key2|$key2.{0,$NEAR}$provenance" \
   && [[ "$disarmed" == "no" ]]; then
  cat >&2 <<'EOF'
Your last message tied a provenance claim — pre-existing, not yours, not
introduced by this change — to code you are not fixing. The quality gate rises
over time: a file you touch comes up to today's bar, whoever wrote it and
whenever. Provenance is not an exemption, and "I only ran the linter" does not
make the errors someone else's problem.

Pick one, deliberately:
  - It sits in a file this change already touches and the fix is bounded ->
    fix it now, in this change.
  - It is genuinely separate work -> file it (.agents/breadcrumbs.md for work,
    .agents/debt-log.md for a standing tradeoff) and name where you filed it.
Do not narrate the reasoning in a code comment.

This check is deliberately aggressive. It fires on the claim, because a silent
punt is word-identical to an honest answer — "those tests are pre-existing"
reads the same whether it dodges work or answers a question you were asked. The
regex cannot see which; you can. If it misread you — you were answering a direct
question about blame, or the code genuinely is not yours to touch — say so in
one line and stop. That is expected and cheap, not a failure.
EOF
  exit 2
fi

exit 0

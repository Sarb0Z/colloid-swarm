#!/usr/bin/env bash
# Print the block reason for a provenance claim ratchet-claim.sh found.
#
# Usage: ratchet-reason.sh <claim> [<lead>]
#
# The claim is quoted because the turn may be long and the sentence far from
# where the model is now: it must know which words to answer for. The lead
# names the moment — end of turn, or before a tool call — and the rest is the
# same in both, so the model hears one rule however it is caught.

set -euo pipefail

claim="${1:?ratchet-reason.sh: usage: ratchet-reason.sh <claim> [<lead>]}"
lead="${2:-This turn tied a provenance claim to a defect it is not fixing:}"

printf '%s\n\n    %s\n\n' "$lead" "$claim"
cat <<'EOF'
Pre-existing, not yours, not introduced by this change: none of these is a
disposition. The quality gate rises over time: a file you touch comes up to
today's bar, whoever wrote it and whenever. A failing check in a suite you ran
is yours the moment you saw it, and "it fails without my changes too" does not
make it someone else's problem.

Pick one, deliberately:
  - A check you ran fails, or it sits in a file this change touches ->
    fix it now, in this change, before anything ships.
  - It is genuinely separate work -> file it (.agents/breadcrumbs.md for work,
    .agents/debt-log.md for a standing tradeoff) and name where you filed it.
Do not narrate the reasoning in a code comment.

This check is deliberately aggressive. It fires on the claim, because a silent
punt is word-identical to an honest answer — "those tests are pre-existing"
reads the same whether it dodges work or answers a question you were asked. The
regex cannot see which; you can. If it misread you — you were answering a direct
question about blame, or the code genuinely is not yours to touch — say so in
one line and carry on. That is expected and cheap, not a failure.
EOF

#!/usr/bin/env bash
# Engine-agnostic policy: state the definition of done when a prompt asks for a
# change. A UserPromptSubmit *context* policy, never a gate — it lands before
# the model answers, where additionalContext is non-blocking.
#
# The prose rule already exists in AGENTS.md; this restates it at the moment it
# applies, because adherence to session-start text decays over a long session.
# The signals match an implementation verb near an object ("add a settings
# page", "implement xp", "wire up the endpoint") and fire on roughly 7% of the
# operator's real prompts (measured in knowledge/research/2026-08-21-session-
# corrections-mined.md), so there is no throttle and no session state.
#
# Input  (stdin JSON): {"project_dir": "...", "prompt": "<user prompt>"}
# Output (STDOUT): a JSON object carrying hookSpecificOutput.additionalContext,
#   or nothing. Always exit 0; never blocks.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
enabled="$(python3 "$lib/config.py" "$repo/.agents/config.json" hooks.done_prime.enabled=true)"
[[ "$enabled" == "no" ]] && exit 0

prompt="$(python3 "$lib/payload.py" prompt | tr '\n' ' ')"
[[ -z "$prompt" ]] && exit 0

verbs='\b(implement|build out|wire up|refactor|migrate|revamp|redesign|rewrite|integrate|overhaul|rework|scaffold)\b'
verb_object='\b(add|create|build|make|fix|finish|complete)\b.{0,40}\b(page|screen|form|flow|feature|endpoint|route|component|module|ui|api|crud|dashboard|table|modal|button|migration|model|schema|service|hook|job|pipeline|integration|tests?)\b'

printf '%s' "$prompt" | grep -Eqi "$verbs|$verb_object" || exit 0

read -r -d '' body <<'EOF_BODY' || true
This prompt asks for a change. Done means: the user-facing surface completes
the job — a backend path the product cannot reach is not done; you ran it and
saw the result rather than inferring it; every item in the request, not the
first; the fix lives in the repository, not in a hand-changed system; and
before you call a UI done, render it and look.
EOF_BODY

printf '%s' "$body" | python3 "$lib/emit-context.py" UserPromptSubmit
exit 0

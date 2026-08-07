#!/usr/bin/env bash
# Engine-agnostic policy: prime search-and-cite discipline on a research-shaped
# prompt. A UserPromptSubmit *context* policy, never a gate — it fires before the
# answer, when the user's question looks like it turns on a current/external
# fact, and injects a non-blocking reminder to search and cite. Silent otherwise.
#
# This is the honest realization of a "nudge": a Stop hook cannot remind the
# model without blocking the turn, so the reminder lands here instead — before
# the model answers — where additionalContext is supported and non-blocking.
#
# Input  (stdin JSON): {"project_dir": "...", "prompt": "<user prompt>"}
# Output (STDOUT): a JSON object carrying hookSpecificOutput.additionalContext,
#   or nothing. Always exit 0; never blocks.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
enabled="$(python3 "$lib/config.py" "$repo/.agents/config.json" hooks.research_prime.enabled=true)"
[[ "$enabled" == "no" ]] && exit 0

prompt="$(python3 "$lib/payload.py" prompt | tr '\n' ' ')"

[[ -z "$prompt" ]] && exit 0

# High-signal patterns: the answer likely turns on a current or external fact.
# Kept tight on purpose — a reminder that fires every turn is one nobody reads.
# Scoped to currency/external-fact intent — bare 'current', 'documentation',
# 'support for', 'most recent', 'deprecat' were dropped: they fire on ordinary
# in-repo work ("current timestamp", "write documentation", "add support for…").
signals='(\blatest\b|\bnewest\b|\bcurrent(ly)? (version|release|stable|state|status|best)\b|\bas of\b|\bup[ -]?to[ -]?date\b|\bnowadays\b|\bthese days\b|\bcompatib|\bwhich version\b|\bwhat version\b|\baccording to\b|\bbest practice\b|\brecommended (way|approach)\b|\blook up\b|\bsearch (for|online|the web)\b|\bgoogle\b|\bchangelog\b|\brelease notes?\b|\bdocs? (for|say)\b)'

printf '%s' "$prompt" | grep -Eqi "$signals" || exit 0

read -r -d '' body <<'EOF' || true
This question looks like it turns on a current or external fact. Don't answer
from memory — search and cite: a quick WebSearch + WebFetch of the primary
source for a single known fact, or delegate a researcher cell (the
`search-and-cite` skill) for anything load-bearing. End with a Sources list of
the URLs you actually used.
EOF

printf '%s' "$body" | python3 "$lib/emit-context.py" UserPromptSubmit
exit 0

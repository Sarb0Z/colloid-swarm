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
cfg_path="$repo/.agents/config.json"
enabled="$(CFG_PATH="$cfg_path" python3 <<'PY'
import json, os
cfg = {}
try:
    with open(os.environ["CFG_PATH"], encoding="utf-8") as f: cfg = json.load(f)
except Exception: pass
print("yes" if cfg.get("hooks", {}).get("research_prime", {}).get("enabled", True) else "no")
PY
)"
[[ "$enabled" == "no" ]] && exit 0

prompt="$(HOOK_INPUT="$(cat)" python3 <<'PY'
import json, os
try:
    d = json.loads(os.environ.get("HOOK_INPUT") or "{}")
except Exception:
    d = {}
p = d.get("prompt")
print((p if isinstance(p, str) else "").replace("\n", " "))
PY
)"

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

HOOK_BODY="$body" python3 <<'PY'
import json, os
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": os.environ["HOOK_BODY"].strip(),
    }
}))
PY
exit 0

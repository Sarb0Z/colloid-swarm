#!/usr/bin/env bash
# Engine-agnostic policy: block end-of-turn when the last assistant
# message hedges or declares the task out of scope.
#
# Input  (stdin JSON): {"transcript_path": "...", "stop_hook_active": bool}
# Output: exit 2 + stderr reason on hedge; exit 0 otherwise.
#
# Only wired where the host engine exposes a transcript path (Claude
# Code today). Silent no-op if transcript_path is missing.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cfg_path="$repo/.agents/config.json"
enabled="$(CFG_PATH="$cfg_path" python3 <<'PY'
import json, os
cfg = {}
try:
    with open(os.environ["CFG_PATH"], encoding="utf-8") as f: cfg = json.load(f)
except Exception: pass
print("yes" if cfg.get("hooks", {}).get("stop_investigate", {}).get("enabled", True) else "no")
PY
)"
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

exit 0

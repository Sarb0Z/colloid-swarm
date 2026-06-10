#!/usr/bin/env bash
# Engine-agnostic policy: log every web lookup to the sources evidence trail.
#
# A PostToolUse capture hook — it observes search/fetch/browse calls (the main
# agent's and any researcher cell's, since subagents inherit hooks) and appends
# one row to .agents/.sources-ledger. It is a *trail*, never a gate: it always
# exits 0 and never blocks a tool.
#
# Input  (stdin JSON): {"project_dir": "...", "agent": "...", "kind": "search|fetch|browse", "value": "<query-or-url>"}
# Output: none; side effect is the appended ledger row `ts \t agent \t kind \t value`.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cfg_path="$repo/.agents/config.json"
enabled="$(CFG_PATH="$cfg_path" python3 <<'PY'
import json, os
cfg = {}
try:
    with open(os.environ["CFG_PATH"], encoding="utf-8") as f: cfg = json.load(f)
except Exception: pass
print("yes" if cfg.get("hooks", {}).get("sources_capture", {}).get("enabled", True) else "no")
PY
)"
[[ "$enabled" == "no" ]] && exit 0

HOOK_INPUT="$(cat)" python3 <<'PY'
import json, os, time

try:
    d = json.loads(os.environ.get("HOOK_INPUT") or "{}")
except Exception:
    raise SystemExit(0)                      # unreadable payload -> nothing to log

def s(x, default=""):                        # coerce: a non-string field is not a crash
    return x if isinstance(x, str) else default

value = s(d.get("value")).strip()
if not value:
    raise SystemExit(0)                      # no source to record

proj = s(d.get("project_dir")) or os.environ.get("CLAUDE_PROJECT_DIR") or "."
ledger = os.path.join(proj, ".agents", ".sources-ledger")
agent = s(d.get("agent"), "main").strip() or "main"
kind = s(d.get("kind"), "fetch").strip() or "fetch"
value = value.replace("\t", " ").replace("\n", " ")[:500]   # one clean row
ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

try:
    with open(ledger, "a", encoding="utf-8") as f:
        f.write("%s\t%s\t%s\t%s\n" % (ts, agent, kind, value))
except OSError:
    pass                                     # a trail that can't be written is not fatal
PY
exit 0

#!/usr/bin/env bash
# Engine-agnostic policy: lint / format / typecheck edited files.
#
# Input  (stdin JSON): {"project_dir": "...", "files": ["...", ...]}
# Output: exit 2 + stderr findings on issues; exit 0 otherwise.
#
# Scoped strictly to the provided file list — never sweeps the repo.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cfg_path="$repo/.agents/config.json"
enabled="$(CFG_PATH="$cfg_path" python3 <<'PY'
import json, os
cfg = {}
try:
    with open(os.environ["CFG_PATH"], encoding="utf-8") as f: cfg = json.load(f)
except Exception: pass
print("yes" if cfg.get("hooks", {}).get("post_edit_check", {}).get("enabled", True) else "no")
PY
)"
[[ "$enabled" == "no" ]] && exit 0

input="$(cat)"

proj="$(HOOK_INPUT="$input" python3 <<'PY'
import json, os
d = json.loads(os.environ["HOOK_INPUT"] or "{}")
print(d.get("project_dir", ""))
PY
)"

files="$(HOOK_INPUT="$input" python3 <<'PY'
import json, os
d = json.loads(os.environ["HOOK_INPUT"] or "{}")
seen = set()
for p in d.get("files") or []:
    if isinstance(p, str) and p and p not in seen:
        seen.add(p)
        print(p)
PY
)"

[[ -z "$files" ]] && exit 0
[[ -z "$proj" ]] && proj="$PWD"
cd "$proj"

issues=""
ran_tsc=false
ts_edited=""

while IFS= read -r f; do
  [[ -z "$f" || ! -f "$f" ]] && continue
  rel="${f#$proj/}"

  case "$f" in
    *.py)
      if command -v ruff >/dev/null 2>&1; then
        ruff check --fix --force-exclude --quiet "$f" >/dev/null 2>&1 || true
        ruff format --force-exclude --quiet "$f" >/dev/null 2>&1 || true
        if ! check_out="$(ruff check --force-exclude --quiet --output-format=concise "$f" 2>&1)"; then
          issues+=$'\n'"[ruff] $rel"$'\n'"$check_out"$'\n'
        fi
      fi
      ;;
    *.ts|*.tsx)
      ts_edited+=$'\n'"$f"
      if [[ "$ran_tsc" == "false" && -x "frontend/node_modules/.bin/tsc" ]]; then
        ran_tsc=true
        tsc_raw="$(cd frontend && ./node_modules/.bin/tsc --noEmit --incremental --tsBuildInfoFile .tsbuildinfo-claude 2>&1 || true)"
        if [[ -n "$tsc_raw" ]]; then
          scoped="$(HOOK_INPUT="$tsc_raw" TS_FILES="$ts_edited" python3 <<'PY'
import os
raw = os.environ["HOOK_INPUT"]
edited = [p.strip() for p in os.environ["TS_FILES"].splitlines() if p.strip()]
rels = []
for p in edited:
    p = p.replace("\\", "/")
    i = p.find("/frontend/")
    if i >= 0:
        rels.append(p[i + len("/frontend/"):])
    elif p.startswith("frontend/"):
        rels.append(p[len("frontend/"):])
    else:
        rels.append(p.split("/")[-1])
keep = [line for line in raw.splitlines() if any(r and r in line for r in rels)]
print("\n".join(keep))
PY
)"
          if [[ -n "$scoped" ]]; then
            issues+=$'\n'"[tsc --noEmit] (scoped to edited files)"$'\n'"$scoped"$'\n'
          fi
        fi
      fi
      ;;
  esac
done <<< "$files"

if [[ -n "$issues" ]]; then
  cat >&2 <<EOF
Post-edit checks found issues — fix them before moving on. These are
scoped to the files you just edited; pre-existing issues elsewhere are
suppressed.
$issues
EOF
  exit 2
fi

exit 0

#!/usr/bin/env bash
# Drive the device policy kit without installing it.
#
# The installer writes to a machine-level path under sudo, so this test builds
# the payload into a temporary directory and runs the helper there. It proves
# the envelope shape Claude Code demands, which is the failure that would stop
# Claude Code from starting on every repository at once.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
device="$here/claude/device"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
fails=0

check() {
  if [ "$2" = "0" ]; then echo "ok    $1"; else echo "FAIL  $1"; fails=$((fails + 1)); fi
}

if python3 "$device/build.py" "$staging" >/dev/null 2>"$staging/build-stderr.txt"
then check "build.py writes a payload" 0
else
  check "build.py writes a payload" 1
  sed 's/^/      /' "$staging/build-stderr.txt"
fi

cp "$device/policy-helper.sh" "$staging/"
chmod 755 "$staging/policy-helper.sh"

if "$staging/policy-helper.sh" > "$staging/stdout.json" 2>"$staging/stderr.txt"
then check "the helper exits 0" 0; else check "the helper exits 0" 1; fi
check "the helper writes nothing to stderr" \
  "$([ ! -s "$staging/stderr.txt" ] && echo 0 || echo 1)"

if python3 - "$staging/stdout.json" "$here/claude/settings.json" "$here/claude/output-style.md" <<'PY'
import json, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
settings = json.load(open(sys.argv[2], encoding="utf-8"))
style = open(sys.argv[3], encoding="utf-8").read().split("\n---\n", 1)[1].strip()
problems = []
if set(document) - {"managedSettings", "claudeMd", "appendSystemPrompt"}:
    problems.append(f"keys outside the envelope: {sorted(set(document))}")
if not document.get("appendSystemPrompt", "").strip():
    problems.append("appendSystemPrompt is empty")
if "No outward mutation" not in document.get("appendSystemPrompt", ""):
    problems.append("appendSystemPrompt omits the outward-mutation rule")
if document.get("appendSystemPrompt", "").strip() != style:
    problems.append("appendSystemPrompt has drifted from the output-style body")
ask = document.get("managedSettings", {}).get("permissions", {}).get("ask", [])
if ask != settings["permissions"]["ask"]:
    problems.append("the payload ask list has drifted from settings.json")
# A static managed payload rejects these keys; only helper stdout carries them.
forbidden = {"appendSystemPrompt", "claudeMd", "policyHelper", "policyHelpers",
             "path", "script", "interpreter", "timeoutMs", "refreshIntervalMs",
             "defaultSettings"}
if set(document.get("managedSettings", {})) & forbidden:
    problems.append("managedSettings carries envelope or helper-entry keys")
for problem in problems:
    print(f"FAIL  {problem}")
raise SystemExit(1 if problems else 0)
PY
then check "the payload matches the envelope Claude Code accepts" 0
else check "the payload matches the envelope Claude Code accepts" 1; fi

if python3 - "$device/managed-settings.json" <<'PY'
import json, sys
entry = json.load(open(sys.argv[1], encoding="utf-8"))["policyHelper"]
problems = []
if set(entry) - {"path", "script", "interpreter", "timeoutMs",
                 "refreshIntervalMs", "defaultSettings"}:
    problems.append(f"unknown policyHelper fields: {sorted(entry)}")
# Inline scripts are rejected on the singular policyHelper key.
if "script" in entry:
    problems.append("the singular policyHelper key rejects an inline script")
if not entry.get("path", "").endswith("policy-helper.sh"):
    problems.append("path does not name the installed helper")
for problem in problems:
    print(f"FAIL  {problem}")
raise SystemExit(1 if problems else 0)
PY
then check "managed-settings.json names a valid policyHelper entry" 0
else check "managed-settings.json names a valid policyHelper entry" 1; fi

echo
if [ "$fails" = "0" ]; then echo "ALL PASS"; else echo "$fails FAILURE(S)"; exit 1; fi

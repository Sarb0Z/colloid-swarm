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

# Account limits: a machine-local file names signed-in accounts whose sessions
# get extra managed settings. The helper picks the payload by the email in the
# profile's `.claude.json`, under the scrubbed environment Claude Code gives it.
limited="$staging/limited"
mkdir -p "$limited"
printf '{"Listed@Example.com": {"deniedModels": ["fable"]}}\n' > "$staging/limits.json"
if python3 "$device/build.py" "$limited" "$staging/limits.json" >/dev/null 2>"$staging/limited-stderr.txt"
then check "build.py writes a payload per limited account" 0
else
  check "build.py writes a payload per limited account" 1
  sed 's/^/      /' "$staging/limited-stderr.txt"
fi
cp "$device/policy-helper.sh" "$limited/"
chmod 755 "$limited/policy-helper.sh"

account() {  # account <dir> <email|-> : write a profile's .claude.json
  mkdir -p "$1"
  if [ "$2" = "-" ]; then printf '{"numStartups": 3}\n' > "$1/.claude.json"
  else printf '{"oauthAccount": {"emailAddress": "%s"}}\n' "$2" > "$1/.claude.json"; fi
}
envelope='
import json, sys
document = json.load(sys.stdin)
assert document["appendSystemPrompt"].strip()
assert "Artifact" in document["managedSettings"]["permissions"]["ask"]
print(document["managedSettings"].get("deniedModels"))'
denied() {  # denied <home> [<config dir>] : print the payload's deniedModels
  if [ $# -eq 2 ]; then
    env -i HOME="$1" CLAUDE_CONFIG_DIR="$2" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      "$limited/policy-helper.sh"
  else
    env -i HOME="$1" PATH=/usr/bin:/bin:/usr/sbin:/sbin "$limited/policy-helper.sh"
  fi | python3 -c "$envelope"
}
account "$staging/h-listed/.claude-guest" "listed@example.com"
# Shaped like a real profile file: nulls, nesting, other emails elsewhere.
mkdir -p "$staging/h-real/.claude-guest"
printf '%s\n' '{"numStartups": 41, "customApiKeyResponses": null,' \
  '"projects": {"/x": {"allowedTools": [], "lastCost": 0.5, "note": "ask other@example.com"}},' \
  '"oauthAccount": {"accountUuid": "a1", "emailAddress": "listed@example.com",' \
  '"organizationUuid": "o1", "organizationName": null}}' > "$staging/h-real/.claude-guest/.claude.json"
account "$staging/h-listed" "someone@example.com"
account "$staging/h-default" "LISTED@example.com"
account "$staging/h-other/.p" "someone@example.com"
account "$staging/h-out/.p" "-"
# Without the guard this email would reach the listed account's payload.
account "$staging/h-dots/.p" "../accounts/listed@example.com"
check "a listed account's profile gets its denied models" \
  "$([ "$(denied "$staging/h-listed" "$staging/h-listed/.claude-guest")" = "['fable']" ] && echo 0 || echo 1)"
check "a profile file shaped like a real one is read" \
  "$([ "$(denied "$staging/h-real" "$staging/h-real/.claude-guest")" = "['fable']" ] && echo 0 || echo 1)"
# Claude Code's subprocess scrub lists CLAUDE_CONFIG_DIR; claudeg's
# CLAUDE_PROFILE=guest still finds the profile.
check "CLAUDE_PROFILE finds the profile when CLAUDE_CONFIG_DIR is stripped" \
  "$([ "$(env -i HOME="$staging/h-listed" CLAUDE_PROFILE=guest PATH=/usr/bin:/bin:/usr/sbin:/sbin \
          "$limited/policy-helper.sh" | python3 -c "$envelope")" = "['fable']" ] && echo 0 || echo 1)"
env -i CLAUDE_PROFILE=guest PATH=/usr/bin:/bin:/usr/sbin:/sbin "$limited/policy-helper.sh" \
  2>"$staging/nohome-stderr.txt" | python3 -c "$envelope" >/dev/null
check "the helper emits a valid policy with HOME stripped" "$?"
check "a listed account in the default profile, in any case, gets them" \
  "$([ "$(denied "$staging/h-default")" = "['fable']" ] && echo 0 || echo 1)"
check "another account gets the shared policy" \
  "$([ "$(denied "$staging/h-listed")" = "None" ] && [ "$(denied "$staging/h-other" "$staging/h-other/.p")" = "None" ] && echo 0 || echo 1)"
check "a signed-out profile gets the shared policy" \
  "$([ "$(denied "$staging/h-out" "$staging/h-out/.p")" = "None" ] && echo 0 || echo 1)"
check "a profile with no account file gets the shared policy" \
  "$([ "$(denied "$staging/h-none" "$staging/h-none/.p")" = "None" ] && echo 0 || echo 1)"
check "an email that is a path cannot pick another file" \
  "$([ "$(denied "$staging/h-dots" "$staging/h-dots/.p")" = "None" ] && echo 0 || echo 1)"
env -i HOME="$staging/h-listed" CLAUDE_CONFIG_DIR="$staging/h-listed/.claude-guest" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin "$limited/policy-helper.sh" >/dev/null 2>"$staging/limited-helper-stderr.txt"
check "the helper writes nothing to stderr for a limited account" \
  "$([ ! -s "$staging/limited-helper-stderr.txt" ] && echo 0 || echo 1)"
for bad in '{"not-an-email": {"deniedModels": ["fable"]}}' \
           '{"a/b@example.com": {"deniedModels": ["fable"]}}' \
           '{"x@example.com": ["fable"]}' \
           '{"x@example.com": {"policyHelper": {}}}' \
           '{".x@example.com": {"deniedModels": ["fable"]}}' \
           '{"X@example.com": {"deniedModels": ["fable"]}, "x@example.com": {"deniedModels": ["opus"]}}' \
           '{"x@example.com": {"deniedModel": ["fable"]}}' \
           '{"x@example.com": {"deniedModels": "fable"}}' \
           '{"x@example.com": {"deniedModels": ["fable"], "permissions": {"deny": ["WebFetch"]}}}'; do
  printf '%s\n' "$bad" > "$staging/bad-limits.json"
  if python3 "$device/build.py" "$staging/bad-$RANDOM" "$staging/bad-limits.json" >/dev/null 2>&1
  then check "build.py refuses limits $bad" 1
  else check "build.py refuses limits $bad" 0; fi
done
# Rebuilding the same folder without limits drops every account payload.
python3 "$device/build.py" "$limited" >/dev/null
check "a rebuild with no listed account leaves no accounts folder" \
  "$([ ! -e "$limited/accounts" ] && echo 0 || echo 1)"

# The installer reaches its sudo step whether the account's style is a link to
# this repository's file or a stale copy. `sudo` and `ls` are stubs that log
# their arguments, so nothing is installed and no machine path is read.
stubs="$staging/stubs"
mkdir -p "$stubs"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$staging/sudo.log" > "$stubs/sudo"
printf '#!/bin/sh\nexit 0\n' > "$stubs/ls"
chmod 755 "$stubs/sudo" "$stubs/ls"
for form in link copy; do
  home="$staging/home-$form"
  mkdir -p "$home/.claude/output-styles"
  if [ "$form" = link ]; then
    ln -s "$here/claude/output-style.md" "$home/.claude/output-styles/colloid.md"
  else
    printf 'a stale style\n' > "$home/.claude/output-styles/colloid.md"
  fi
  : > "$staging/sudo.log"
  if env -u CLAUDE_ACCOUNT_LIMITS HOME="$home" PATH="$stubs:$PATH" \
       bash "$here/claude/install-device-policy.sh" \
       > "$staging/install-$form.txt" 2>&1 \
     && grep -q 'policy.json' "$staging/sudo.log" \
     && cmp -s "$home/.claude/output-styles/colloid.md" "$here/claude/output-style.md"
  then check "the installer reaches sudo with the account's style as a $form" 0
  else
    check "the installer reaches sudo with the account's style as a $form" 1
    sed 's/^/      /' "$staging/install-$form.txt"
  fi
done
[ -L "$staging/home-link/.claude/output-styles/colloid.md" ]
check "the installer keeps the account's link" "$?"
! grep -q 'cp -R' "$staging/sudo.log"
check "the installer copies no account payloads when no limits file exists" "$?"

: > "$staging/sudo.log"
if CLAUDE_ACCOUNT_LIMITS="$staging/limits.json" HOME="$staging/home-copy" PATH="$stubs:$PATH" \
     bash "$here/claude/install-device-policy.sh" > "$staging/install-limits.txt" 2>&1 \
   && grep -q 'cp -R .*/accounts .*/ClaudeCode/accounts' "$staging/sudo.log"
then check "the installer installs the account payloads from a limits file" 0
else
  check "the installer installs the account payloads from a limits file" 1
  sed 's/^/      /' "$staging/install-limits.txt"
fi

echo
if [ "$fails" = "0" ]; then echo "ALL PASS"; else echo "$fails FAILURE(S)"; exit 1; fi

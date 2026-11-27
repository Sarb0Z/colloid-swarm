#!/usr/bin/env bash
# Install the device-wide Claude Code policy: the counter-pressure text in the
# system prompt, and the outward-mutation ask rules, for every session on this
# machine regardless of which repository it starts in.
#
# `AGENTS.md` §External actions governs what the policy enforces. This script
# writes to a machine-level path and needs sudo, so it is never run as part of
# a task. The operator runs it deliberately, in a terminal that can prompt.
#
# Revert with: sudo rm -rf "/Library/Application Support/ClaudeCode"

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="/Library/Application Support/ClaudeCode"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

# Per-account limits, such as models one signed-in account may not use, live in
# a machine-local file: the accounts on this machine are not the scaffold's.
limits="${CLAUDE_ACCOUNT_LIMITS:-$HOME/.config/claude-policy/account-limits.json}"
if [ -f "$limits" ]; then
  python3 "$here/device/build.py" "$staging" "$limits"
else
  python3 "$here/device/build.py" "$staging"
fi
cp "$here/device/policy-helper.sh" "$here/device/managed-settings.json" "$staging/"

# A malformed payload stops Claude Code from starting, so prove the helper runs
# and emits the envelope before anything reaches the machine-level path.
chmod 755 "$staging/policy-helper.sh"
"$staging/policy-helper.sh" | python3 -c '
import json, sys
document = json.load(sys.stdin)
assert set(document) <= {"managedSettings", "claudeMd", "appendSystemPrompt"}, document.keys()
assert document["appendSystemPrompt"].strip()
assert "Artifact" in document["managedSettings"]["permissions"]["ask"]
print("verified: helper emits a valid policy envelope")
'
# The helper serves an account's payload to that account alone, so each one
# is checked here too: a broken one would stop only that account's sessions.
for account in "$staging/accounts/"*.json; do
  [ -e "$account" ] || continue
  python3 - "$account" "$staging/policy.json" <<'PY'
import json, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
shared = json.load(open(sys.argv[2], encoding="utf-8"))
assert set(document) <= {"managedSettings", "claudeMd", "appendSystemPrompt"}, document.keys()
assert document["appendSystemPrompt"] == shared["appendSystemPrompt"]
assert document["managedSettings"]["permissions"] == shared["managedSettings"]["permissions"]
print(f"verified: {sys.argv[1].rsplit('/', 1)[1]} keeps the shared policy and adds "
      f"{sorted(set(document['managedSettings']) - set(shared['managedSettings']))}")
PY
done

# The user-tier output style is the fallback that covers every launch surface
# when the managed policy is absent, and it needs no sudo. It is the same file
# the project tier links and the device payload reads, so no tier can drift.
style="$HOME/.claude/output-styles/colloid.md"
mkdir -p "$(dirname "$style")"
# A machine that links this path to the repository's file already has it; cp
# onto that link exits 1 ("identical (not copied)"), which would stop the install.
if [ "$style" -ef "$here/output-style.md" ]; then
  echo "kept $style, which links to $here/output-style.md"
else
  cp "$here/output-style.md" "$style"
  echo "wrote $style"
fi
echo "Leave it unselected while this policy is installed: the policy appends the same text, and selecting it as well puts it in the prompt twice."
echo

echo "Installing to $target — sudo will prompt."
sudo mkdir -p "$target"
sudo cp "$staging/policy-helper.sh" "$staging/policy.json" \
        "$staging/managed-settings.json" "$target/"
sudo chmod 755 "$target/policy-helper.sh"
sudo chmod 644 "$target/policy.json" "$target/managed-settings.json"
# An account taken off the limits file loses its payload here.
sudo rm -rf "$target/accounts"
if [ -d "$staging/accounts" ]; then
  sudo cp -R "$staging/accounts" "$target/accounts"
  sudo chmod 755 "$target/accounts"
  sudo chmod 644 "$target/accounts/"*.json
fi
ls -lR "$target"
echo
echo "Start a new Claude Code session and check /status for policy warnings."
echo "Revert with: sudo rm -rf \"$target\""

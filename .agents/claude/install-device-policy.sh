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

python3 "$here/device/build.py" "$staging"
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

# The user-tier output style is the fallback that covers every launch surface
# when the managed policy is absent, and it needs no sudo. It is the same file
# the project tier links and the device payload reads, so no tier can drift.
style="$HOME/.claude/output-styles/colloid.md"
mkdir -p "$(dirname "$style")"
cp "$here/output-style.md" "$style"
echo "wrote $style"
echo "Select it with \"outputStyle\": \"colloid\" in ~/.claude/settings.json."
echo

echo "Installing to $target — sudo will prompt."
sudo mkdir -p "$target"
sudo cp "$staging/policy-helper.sh" "$staging/policy.json" \
        "$staging/managed-settings.json" "$target/"
sudo chmod 755 "$target/policy-helper.sh"
sudo chmod 644 "$target/policy.json" "$target/managed-settings.json"
ls -l "$target"
echo
echo "Start a new Claude Code session and check /status for policy warnings."
echo "Revert with: sudo rm -rf \"$target\""

#!/bin/sh
# Claude Code policy helper for the Linux server: write the device-wide policy
# envelope to stdout. A port of .agents/claude/device/policy-helper.sh, which
# Claude Code on the Mac runs; setup-server.sh installs this one as
# /etc/claude-code/policy-helper.sh, beside policy.json and accounts/<email>.json.
#
# A helper that fails stops Claude Code from starting, so a profile with no
# account file or no signed-in account is a normal state and gets the shared
# policy; only a missing payload fails.
#
# The profile folder is CLAUDE_CONFIG_DIR when set, else the one CLAUDE_PROFILE
# names in the launchers (launchers.bash), else the home folder. Claude Code's
# subprocess scrub lists CLAUDE_CONFIG_DIR and HOME, so the home folder comes
# from the passwd database when HOME is gone. Claude Code runs this with a
# minimal PATH, so every tool is named by its path.
set -eu
here=$(dirname "$0")
payload="$here/policy.json"
home="${HOME:-}"
if [ -z "$home" ]; then
  home=$(/usr/bin/getent passwd "$(/usr/bin/id -un)" | /usr/bin/cut -d: -f6 || true)
fi
profile="${CLAUDE_CONFIG_DIR:-}"
if [ -z "$profile" ]; then
  case "${CLAUDE_PROFILE:-}" in
    work|personal|family|guest) profile="$home/.claude-$CLAUDE_PROFILE" ;;
    *) profile="$home" ;;
  esac
fi
if [ -d "$here/accounts" ] && [ -n "$profile" ] && [ -r "$profile/.claude.json" ]; then
  email=$(/usr/bin/jq -r '.oauthAccount.emailAddress // empty' "$profile/.claude.json" 2>/dev/null \
            | /usr/bin/tr '[:upper:]' '[:lower:]' || true)
  case "$email" in
    ""|*/*|.*) ;;
    *) if [ -f "$here/accounts/$email.json" ]; then payload="$here/accounts/$email.json"; fi ;;
  esac
fi
exec /bin/cat "$payload"

#!/bin/sh
# Claude Code policy helper: write the device-wide policy envelope to stdout.
#
# Claude Code accepts `appendSystemPrompt` from helper stdout only. A static
# managed payload rejects the key, and no settings file carries it, so this
# indirection is the only route that reaches the system prompt without a
# command-line flag.
#
# `build.py` writes policy.json beside this script at install time, and one
# payload per limited account under accounts/. The payload is data so the
# operator can revise the text without replacing an executable that every
# Claude Code start runs.
#
# The account is the one signed in to the profile this session starts with:
# `.claude.json` sits in CLAUDE_CONFIG_DIR when it is set, in the home folder
# otherwise. Claude Code's subprocess scrub lists CLAUDE_CONFIG_DIR and HOME,
# so neither is relied on alone: CLAUDE_PROFILE, which the claudep/claudef/
# claudeg launchers set and Claude Code does not know, maps back to the
# profile folder as ~/.zshenv maps it, and the home folder comes from the
# directory service when HOME is gone. Claude Code runs this with
# PATH=/usr/bin:/bin:/usr/sbin:/sbin, so the email is read with plutil, which
# parses JSON. A profile with no account file or no signed-in account is a
# normal state and gets the shared policy.
set -eu
here=$(dirname "$0")
payload="$here/policy.json"
home="${HOME:-}"
if [ -z "$home" ]; then
  home=$(/usr/bin/dscl . -read "/Users/$(/usr/bin/id -un)" NFSHomeDirectory 2>/dev/null \
           | /usr/bin/sed -n 's/^NFSHomeDirectory: //p' || true)
fi
profile="${CLAUDE_CONFIG_DIR:-}"
if [ -z "$profile" ]; then
  case "${CLAUDE_PROFILE:-}" in
    personal|family|guest) profile="$home/.claude-$CLAUDE_PROFILE" ;;
    *) profile="$home" ;;
  esac
fi
if [ -d "$here/accounts" ] && [ -n "$profile" ] && [ -r "$profile/.claude.json" ]; then
  email=$(/usr/bin/plutil -extract oauthAccount.emailAddress raw -o - \
            "$profile/.claude.json" 2>/dev/null | /usr/bin/tr '[:upper:]' '[:lower:]' || true)
  case "$email" in
    ""|*/*|.*) ;;
    *) if [ -f "$here/accounts/$email.json" ]; then payload="$here/accounts/$email.json"; fi ;;
  esac
fi
exec /bin/cat "$payload"

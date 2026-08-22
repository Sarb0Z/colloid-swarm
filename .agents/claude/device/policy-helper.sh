#!/bin/sh
# Claude Code policy helper: write the device-wide policy envelope to stdout.
#
# Claude Code accepts `appendSystemPrompt` from helper stdout only. A static
# managed payload rejects the key, and no settings file carries it, so this
# indirection is the only route that reaches the system prompt without a
# command-line flag.
#
# `build.py` writes policy.json beside this script at install time. The payload
# is data so the operator can revise the text without replacing an executable
# that every Claude Code start runs.
set -eu
exec /bin/cat "$(dirname "$0")/policy.json"

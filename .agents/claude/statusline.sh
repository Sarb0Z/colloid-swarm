#!/bin/bash
# Claude Code status line: a silent relay for the status band.
#
# The band (.agents/claude/mods/status-band) draws the status above the prompt.
# A mod cannot read four values only this JSON carries (effort, fast mode, the
# live vim state, lines added and removed), so this script hands the JSON on.
# The two meet in one per-user folder keyed by session id:
#
#   ${TMPDIR:-/tmp}/colloid-status-$USER/<session>.on    the band's marker
#   ${TMPDIR:-/tmp}/colloid-status-$USER/<session>.json  this script's copy
#
# With the marker present, the JSON goes to <session>.json and nothing prints;
# that path starts no process but mv, since it runs on every refresh. Without
# it (the band switched off, not loaded, or a Claude Code without mods), the
# person's own user statusLine runs instead, because the project setting would
# otherwise leave them with nothing.
#
# Wired as the project statusLine in .agents/claude/settings.json.

IFS= read -r -d '' input || true

session=""
id_field='"session_id"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ $input =~ $id_field ]] && session=${BASH_REMATCH[1]}
folder="${TMPDIR:-/tmp}"
folder="${folder%/}/colloid-status-${USER:-}"

# The id names files, so only readout.py's id alphabet passes; the folder must
# be this user's own, not a link another user planted in a shared /tmp.
if [[ -n ${USER:-} && $session =~ ^[A-Za-z0-9_-]+$ && -f "$folder/$session.on" && -O "$folder" && ! -L "$folder" ]]; then
  printf '%s' "$input" > "$folder/.$session.$$.tmp" && mv -f "$folder/.$session.$$.tmp" "$folder/$session.json"
  exit 0
fi

# A user status line that runs this script again would loop; the marker stops
# the second pass.
[ -n "${COLLOID_STATUS_DELEGATED:-}" ] && exit 0
# Read with python3, not jq: the person is owed their own status line even on a
# machine without jq.
settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
if ! own=$(python3 - "$settings" <<'PY'
import json, os, sys
if os.path.exists(sys.argv[1]):
    with open(sys.argv[1], encoding="utf-8") as source:
        print((json.load(source).get("statusLine") or {}).get("command", ""))
PY
); then
  printf 'status line: %s is unreadable\n' "$settings"
  exit 0
fi
[ -n "$own" ] || exit 0
printf '%s' "$input" | COLLOID_STATUS_DELEGATED=1 bash -c "$own"

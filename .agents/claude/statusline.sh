#!/bin/bash
# Claude Code status line: a silent relay for the status band.
#
# The band (.agents/claude/mods/status-band) draws the status above the prompt.
# A mod cannot read four values only this JSON carries (effort, fast mode, the
# live vim state, lines added and removed), so this script hands the JSON on.
# The two meet in one per-user folder keyed by session id:
#
#   ${TMPDIR:-/tmp}/colloid-status-$USER/<session>.on     the band's marker
#   ${TMPDIR:-/tmp}/colloid-status-$USER/<session>.json   this script's copy
#   ${TMPDIR:-/tmp}/colloid-status-$USER/<session>.nomod  no band came for it
#
# With the marker present, the JSON goes to <session>.json and nothing prints.
# That path runs on every refresh, so it starts no process but mv. The band
# makes the folder 0700; this script writes its own files under umask 077 and
# leaves the person's command the umask it inherited. Without the
# marker (the band switched off, not loaded, or a Claude Code without mods),
# the person's own user statusLine runs instead, because the project setting
# would otherwise leave them with nothing.
#
# Claude Code runs this before the band's session.start writes the marker, and
# that first line stands until the next refresh. So where the band is
# installed (.claude/skills/colloid-status-band resolves in this checkout) and
# no <session>.nomod says it never came, the first run waits for the marker,
# polling every 0.1 s. Worst case: about 1.6 s added once per session id (15
# polls of `sleep 0.1`), after which <session>.nomod makes every later run for
# that id hand over at once; a marker that appears later still wins.
#
# Wired as the project statusLine in .agents/claude/settings.json.

# A user status line that runs this script again would loop; the marker stops
# the second pass before it waits or writes anything.
[ -n "${COLLOID_STATUS_DELEGATED:-}" ] && exit 0

IFS= read -r -d '' input || true

session=""
id_field='"session_id"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ $input =~ $id_field ]] && session=${BASH_REMATCH[1]}
folder="${TMPDIR:-/tmp}"
folder="${folder%/}/colloid-status-${USER:-}"
checkout="${BASH_SOURCE[0]%/*}/../.."

# The folder must be this user's own, not a link another user planted in a
# shared /tmp.
ours() { [[ -d $folder && -O $folder && ! -L $folder ]]; }

relay() {
  printf '%s' "$input" > "$folder/.$session.$$.tmp" && mv -f "$folder/.$session.$$.tmp" "$folder/$session.json"
}

marked() { [[ -f "$folder/$session.on" ]] && ours; }

# The id names files, so only readout.py's id alphabet passes.
if [[ -n ${USER:-} && $session =~ ^[A-Za-z0-9_-]+$ ]]; then
  if marked; then
    umask 077
    relay
    exit 0
  fi
  if [[ -e "$checkout/.claude/skills/colloid-status-band" && ! -e "$folder/$session.nomod" ]]; then
    # A folder that cannot be made or is not ours (a dangling link, a read-only
    # TMPDIR) gets no wait: no .nomod could end it, so every refresh would wait.
    [[ -e $folder || -L $folder ]] || (umask 077; mkdir "$folder") 2>/dev/null
    if ours; then
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        sleep 0.1
        if marked; then
          umask 077
          relay
          exit 0
        fi
      done
      (umask 077; : > "$folder/$session.nomod")
    fi
  fi
fi

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

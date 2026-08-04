#!/usr/bin/env bash
# Engine-agnostic policy: block destructive shell commands.
#
# Input  (stdin JSON): {"command": "<shell command>"}
# Output: exit 2 + stderr reason on block; exit 0 otherwise.
#
# Claude Code, Kimi CLI, and Codex all treat exit 2 + stderr as "block, feed
# reason to the model", so no per-engine output adapter is needed. Every other
# non-zero exit is a hook failure on all three, and the action proceeds — so a
# policy that cannot run must exit 0 deliberately rather than error.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cfg_path="$repo/.agents/config.json"
enabled="$(CFG_PATH="$cfg_path" python3 <<'PY'
import json, os
cfg = {}
try:
    with open(os.environ["CFG_PATH"], encoding="utf-8") as f: cfg = json.load(f)
except Exception: pass
print("yes" if cfg.get("hooks", {}).get("guard_destructive", {}).get("enabled", True) else "no")
PY
)"
[[ "$enabled" == "no" ]] && exit 0

cmd="$(HOOK_INPUT="$(cat)" python3 <<'PY'
import json, os
d = json.loads(os.environ["HOOK_INPUT"] or "{}")
print(d.get("command", ""))
PY
)"

[[ -z "$cmd" ]] && exit 0

block() { printf '%s\n' "$1" >&2; exit 2; }

# rm -rf against broad / root / home / wildcard paths
if printf '%s' "$cmd" | grep -Eq 'rm[[:space:]]+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r|-rf|-fr)[[:space:]]+(/|~|\$HOME|\*|\.\*)'; then
  block "Destructive rm on a broad path. This is irreversible — confirm with the user, or narrow the path."
fi

# git force-push
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+push[^|;&]*(--force([[:space:]]|=|$)|--force-with-lease|[[:space:]]-f([[:space:]]|$))'; then
  block "Force-push rewrites remote history. Confirm with the user before running."
fi

# git reset --hard
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+reset[[:space:]]+--hard'; then
  block "git reset --hard discards work irreversibly. Confirm with the user, or use stash/branch."
fi

# git commit/push --no-verify (safety-check bypass)
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+(commit|push)[^|;&]*--no-verify'; then
  block "--no-verify bypasses pre-commit/push safety checks. Fix the underlying failure instead of bypassing."
fi

# Production SSH mutations.
if printf '%s' "$cmd" | grep -Eq 'ssh[[:space:]]'; then
  if printf '%s' "$cmd" | grep -Eq '(systemctl[[:space:]]+(restart|stop|start|reload|enable|disable|daemon-reload)|postsuper|postqueue[[:space:]]+-[fd]|apt(-get)?[[:space:]]+(install|remove|purge|upgrade)|yum[[:space:]]+install|dnf[[:space:]]+install|pip[[:space:]]+install|npm[[:space:]]+install|crontab[[:space:]]+-[er]|[[:space:]]tee[[:space:]]|[[:space:]]>[[:space:]]*/etc/|[[:space:]]sed[[:space:]]+-i|rm[[:space:]]+-[rf]|kill(all)?[[:space:]])'; then
    block "Production mutation via SSH is forbidden from local sessions. Ship the change through the repo and the approved deploy path; production access is read-only here."
  fi
fi

# Destructive SQL (DROP / TRUNCATE / unrestricted DELETE or UPDATE)
if printf '%s' "$cmd" | grep -Eqi '(psql|mysql)[^|;&]*(DROP[[:space:]]+(TABLE|DATABASE|SCHEMA|INDEX)|TRUNCATE[[:space:]]+TABLE)'; then
  block "Destructive DDL detected. Confirm with the user and route the change through migrations."
fi
if printf '%s' "$cmd" | grep -Eqi '(psql|mysql)[^|;&]*(DELETE[[:space:]]+FROM[[:space:]]+[A-Za-z_.]+[[:space:]]*;|UPDATE[[:space:]]+[A-Za-z_.]+[[:space:]]+SET[^;]*;)' && ! printf '%s' "$cmd" | grep -Eqi 'WHERE'; then
  block "Unrestricted DELETE/UPDATE (no WHERE clause) detected. Confirm with the user before running."
fi

exit 0

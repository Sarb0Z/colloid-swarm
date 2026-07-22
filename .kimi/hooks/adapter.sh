#!/usr/bin/env bash
# Kimi CLI → shared policy adapter.
#
# Normalizes Kimi hook stdin into the shape the policy scripts expect,
# then runs the named policy. For blockable events (PreToolUse, Stop) the
# exit code / stderr bubble up unchanged — Kimi treats exit 2 + stderr as
# "block, feed reason to the model".
#
# PostToolUse is pure observation in Kimi: exit 2 AND stdout are both
# discarded (verified against 0.29), so post-edit-check findings can never
# reach the model at edit time. Instead they buffer in a per-session state
# file and relay through the next Stop — which IS blockable — so the model
# sees them at end of turn and can fix before the turn closes.

set -euo pipefail

policy="$1"; shift || true
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
input="$(cat)"

sid="$(HOOK_INPUT="$input" python3 -c 'import json,os,re; s=json.loads(os.environ["HOOK_INPUT"] or "{}").get("session_id","nosession"); print(re.sub(r"[^A-Za-z0-9_-]","",s))')"
pending="$repo/.agents/.kimi-pending-findings-$sid"

normalized="$(HOOK_INPUT="$input" POLICY="$policy" REPO="$repo" python3 <<'PY'
import json, os, sys

src = json.loads(os.environ["HOOK_INPUT"] or "{}")
ti = src.get("tool_input") or {}
repo = os.environ["REPO"]
policy = os.environ["POLICY"]

out = {"project_dir": src.get("cwd") or repo}

if policy == "guard-destructive.sh":
    out["command"] = ti.get("command", "")
elif policy == "post-edit-check.sh":
    files = []
    for key in ("file_path", "path"):
        v = ti.get(key)
        if isinstance(v, str):
            files.append(v)
    out["files"] = files
elif policy == "session-wrap.sh":
    out["stop_hook_active"] = bool(src.get("stop_hook_active", False))

sys.stdout.write(json.dumps(out))
PY
)"

run() { printf '%s' "$normalized" | "$repo/.agents/hooks/policy/$(basename "$policy")"; }

case "$(basename "$policy")" in
post-edit-check.sh)
  set +e
  findings="$(run 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 2 && -n "$findings" ]]; then
    printf '%s\n' "$findings" >> "$pending"
  fi
  exit 0
  ;;
session-wrap.sh)
  # Orphans from sessions that died between edit and stop; reap quietly.
  find "$repo/.agents" -maxdepth 1 -name '.kimi-pending-findings-*' -mtime +1 -delete 2>/dev/null || true
  if [[ -s "$pending" ]]; then
    findings="$(cat "$pending")"
    rm -f "$pending"
    printf '%s\n' "$findings" >&2
    exit 2
  fi
  run
  ;;
*)
  run
  ;;
esac

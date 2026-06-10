#!/usr/bin/env bash
# Kimi CLI → shared policy adapter.
#
# Normalizes Kimi hook stdin into the shape the policy scripts expect,
# then execs the named policy. Exit code / stderr bubble up unchanged —
# Kimi treats exit 2 + stderr as "block, feed reason to the model".

set -euo pipefail

policy="$1"; shift || true
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

HOOK_INPUT="$(cat)" POLICY="$policy" REPO="$repo" python3 <<'PY' | exec "$repo/.agents/hooks/policy/$(basename "$policy")"
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

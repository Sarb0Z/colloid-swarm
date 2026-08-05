#!/usr/bin/env bash
# Claude Code → shared policy adapter.
#
# Normalizes Claude hook stdin into the shape the policy scripts expect,
# then execs the named policy. Exit code / stderr bubble up unchanged —
# Claude treats exit 2 + stderr as "block, feed reason to the model".
#
# Optional agent scoping:
#   adapter.sh [--agent <selector>] <policy.sh>
# Claude tags every hook payload fired inside a subagent with agent_type
# (and agent_id); the main agent's payload omits them. The selector gates
# whether the policy runs for this invocation:
#   main      → only the main agent (no agent_type present)
#   subagent  → only subagents (any agent_type present)
#   <Type>    → only the named agent type(s); '|'-separated, e.g.
#               Explore|Plan or a custom subagent name
# Flag absent → runs for every agent, main and subagents alike.

set -euo pipefail

# The shared policies use heredocs inside command substitution, which bash 3.2
# (stock on macOS) cannot parse. Refuse loudly instead of failing per policy.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "hooks: bash $BASH_VERSION is too old (need >= 4); policies are disabled." >&2
  echo "hooks: install a modern bash (e.g. 'brew install bash') and reopen the session." >&2
  exit 0
fi

agent_sel=""
if [[ "${1:-}" == "--agent" ]]; then
  agent_sel="${2:?--agent needs a selector}"; shift 2
fi

policy="$1"; shift || true
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

raw="$(cat)"

# Agent-type gate: with a selector, skip the policy (exit 0, no-op) only
# on an explicit non-match. A match, a malformed payload, or a gate
# failure all fall through to running the policy — a broken gate must
# never silently disable a safety policy.
if [[ -n "$agent_sel" ]]; then
  decision="$(AGENT_SEL="$agent_sel" HOOK_INPUT="$raw" python3 <<'PY'
import json, os

sel = os.environ["AGENT_SEL"]
try:
    src = json.loads(os.environ.get("HOOK_INPUT") or "{}")
    atype = (src.get("agent_type") or "").strip()
except Exception:
    print("run"); raise SystemExit(0)  # unreadable payload → run

if sel == "main":
    match = atype == ""            # main agent omits agent_type
elif sel == "subagent":
    match = atype != ""
else:
    match = atype != "" and atype in sel.split("|")
print("run" if match else "skip")
PY
)" || decision="run"               # gate interpreter failed → run
  if [[ "$decision" == "skip" ]]; then exit 0; fi
fi

policy_path="$repo/.agents/hooks/policy/$(basename "$policy")"
if [[ ! -x "$policy_path" ]]; then
  echo "adapter: unknown or non-executable policy '$policy'" >&2
  exit 1
fi

HOOK_INPUT="$raw" POLICY="$policy" REPO="$repo" python3 <<'PY' | exec "$policy_path"
import json, os, sys

src = json.loads(os.environ["HOOK_INPUT"] or "{}")
ti = src.get("tool_input") or {}
repo = os.environ["REPO"]
policy = os.environ["POLICY"]

out = {"project_dir": os.environ.get("CLAUDE_PROJECT_DIR") or src.get("cwd") or repo}

if policy == "guard-destructive.sh":
    out["command"] = ti.get("command", "")
elif policy == "genome-guard.sh":
    # Task/Agent dispatch input: the subagent's prompt and its type.
    out["prompt"] = ti.get("prompt", "")
    out["subagent_type"] = ti.get("subagent_type", "")
elif policy == "sources-capture.sh":
    # Web lookup -> evidence trail. Map the tool to a kind + the source value;
    # agent_type tags a researcher cell's rows apart from the main agent's.
    tool = src.get("tool_name") or ""
    _a = src.get("agent_type")
    out["agent"] = (_a if isinstance(_a, str) else "main").strip() or "main"
    if tool == "WebSearch" or tool.endswith("__resolve_open_access"):
        out["kind"], out["value"] = "search", ti.get("query", "")
    elif tool == "WebFetch" or tool.endswith("__fetch_readable"):
        out["kind"], out["value"] = "fetch", ti.get("url", "")
    else:                              # browser_navigate carries a url
        out["kind"], out["value"] = "browse", ti.get("url", "")
elif policy == "post-edit-check.sh":
    files = []
    for key in ("file_path", "path", "notebook_path"):
        v = ti.get(key)
        if isinstance(v, str):
            files.append(v)
    for e in ti.get("edits") or []:
        if isinstance(e, dict) and isinstance(e.get("file_path"), str):
            files.append(e["file_path"])
    out["files"] = files
elif policy == "session-wrap.sh":
    out["stop_hook_active"] = bool(src.get("stop_hook_active", False))
    out["transcript_path"] = src.get("transcript_path", "")
    out["session_id"] = src.get("session_id", "")
elif policy == "stop-investigate.sh":
    out["stop_hook_active"] = bool(src.get("stop_hook_active", False))
    out["transcript_path"] = src.get("transcript_path", "")
    msg = src.get("last_assistant_message")
    out["last_assistant_message"] = msg if isinstance(msg, str) else ""
elif policy == "session-start.sh":
    out["source"] = src.get("source", "")
    # Identity, for seeding session-wrap's baseline before turn 1 runs.
    out["session_id"] = src.get("session_id", "")
    out["transcript_path"] = src.get("transcript_path", "")
elif policy == "research-prime.sh":
    out["prompt"] = src.get("prompt", "")
elif policy == "pre-compact.sh":
    out["trigger"] = src.get("trigger", "")

sys.stdout.write(json.dumps(out))
PY

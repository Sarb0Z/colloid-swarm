#!/usr/bin/env bash
# Kimi CLI → shared policy adapter.
#
# Normalizes Kimi hook stdin into the shape the policy scripts expect,
# then runs the named policy. For blockable events (PreToolUse,
# UserPromptSubmit, Stop) the exit code / stderr bubble up unchanged —
# Kimi treats exit 2 + stderr as "block, feed reason to the model".
#
# Per-engine seams this adapter owns (verified against Kimi 0.29):
# - PostToolUse is pure observation: exit 2 AND stdout are both discarded,
#   so post-edit-check findings buffer in a per-session state file and
#   relay through the next Stop — which IS blockable — so the model sees
#   them at end of turn. sources-capture is unaffected (it only logs).
# - Context-injecting policies (session-start, research-prime) emit
#   Claude's {"hookSpecificOutput":{"additionalContext":...}} envelope;
#   Kimi appends raw stdout to context instead, so the adapter unwraps
#   the envelope and prints the plain text.
# - Kimi has no transcript_path; session_id (present on every payload)
#   is the session identity session-wrap keys its throttle state on.
# - UserPromptSubmit's prompt is an array of content parts, not a string.
# - PostCompact maps to session-start.sh with source=compact: Kimi
#   compacts in-session, so the post-compaction re-prime rides the
#   PostCompact event rather than a SessionStart(source=compact).
# - A policy absent from this repo's .agents/hooks/policy/ exits 0
#   silently — the global ~/.kimi-code/config.toml registers the full
#   fleet of hooks, and repos vendor only the policies they carry.

set -euo pipefail

policy="$1"; shift || true
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
policy_path="$repo/.agents/hooks/policy/$(basename "$policy")"
[[ -x "$policy_path" ]] || exit 0

input="$(cat)"

sid="$(HOOK_INPUT="$input" python3 -c 'import json,os,re; s=json.loads(os.environ["HOOK_INPUT"] or "{}").get("session_id","nosession"); print(re.sub(r"[^A-Za-z0-9_-]","",s))')"
pending="$repo/.agents/.kimi-pending-findings-$sid"

normalized="$(HOOK_INPUT="$input" POLICY="$policy" REPO="$repo" python3 <<'PY'
import json, os, sys

src = json.loads(os.environ["HOOK_INPUT"] or "{}")
ti = src.get("tool_input") or {}
repo = os.environ["REPO"]
policy = os.path.basename(os.environ["POLICY"])

out = {"project_dir": src.get("cwd") or repo}

if policy == "guard-destructive.sh":
    out["command"] = ti.get("command", "")
elif policy == "genome-guard.sh":
    # Agent carries prompt; AgentSwarm carries prompt_template. Same guard.
    prompt = ti.get("prompt", "") or ti.get("prompt_template", "")
    out["prompt"] = prompt if isinstance(prompt, str) else ""
    out["subagent_type"] = ti.get("subagent_type", "")
elif policy == "sources-capture.sh":
    tool = src.get("tool_name") or ""
    out["agent"] = "main"          # Kimi payloads carry no subagent tag
    if tool == "WebSearch":
        out["kind"], out["value"] = "search", ti.get("query", "")
    else:                          # FetchURL
        out["kind"], out["value"] = "fetch", ti.get("url", "")
elif policy == "post-edit-check.sh":
    files = []
    for key in ("file_path", "path"):
        v = ti.get(key)
        if isinstance(v, str):
            files.append(v)
    out["files"] = files
elif policy == "session-wrap.sh":
    out["stop_hook_active"] = bool(src.get("stop_hook_active", False))
    out["session_id"] = src.get("session_id", "")
elif policy == "session-start.sh":
    if src.get("hook_event_name") == "PostCompact":
        out["source"] = "compact"
    else:
        out["source"] = src.get("source", "")
elif policy == "research-prime.sh":
    p = src.get("prompt")
    if isinstance(p, list):        # Kimi: array of content parts
        p = " ".join(x.get("text", "") for x in p if isinstance(x, dict))
    out["prompt"] = p if isinstance(p, str) else ""
elif policy == "pre-compact.sh":
    out["trigger"] = src.get("trigger", "") or "auto"

sys.stdout.write(json.dumps(out))
PY
)"

run() { printf '%s' "$normalized" | "$policy_path"; }

# Unwrap Claude's additionalContext envelope into plain stdout for Kimi.
unwrap() {
  OUT="$1" python3 -c '
import json, os
raw = os.environ["OUT"]
try:
    ctx = json.loads(raw)["hookSpecificOutput"]["additionalContext"]
    print(ctx)
except Exception:
    if raw.strip():
        print(raw)
'
}

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
session-start.sh|research-prime.sh)
  set +e
  out="$(run)"
  rc=$?
  set -e
  [[ -n "$out" ]] && unwrap "$out"
  exit $rc
  ;;
*)
  run
  ;;
esac

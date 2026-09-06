#!/usr/bin/env bash
# Engine-agnostic policy: a subagent that starts inside a linked worktree
# gets that worktree's dependencies installed before its first turn.
#
# A worktree is a fresh checkout: no node_modules, no .venv, nothing a test
# can run against. Left alone, the cell's first red test reads as a code
# defect and it starts patching source to satisfy a missing module. So the
# start of the cell is the moment to provision — after the checkout exists,
# before any reasoning has happened — and a provision that fails blocks the
# start (exit 2) rather than handing over a half-built tree.
#
# Input (stdin JSON): {"project_dir": ..., "cwd": ..., "agent_type": ...}
# Output: exit 0 silently for a subagent in the main checkout at any depth;
#   additionalContext naming what was installed for one in a linked worktree;
#   exit 2 with provision.sh's reason when the install fails or expires.
#
# The install runs with lifecycle scripts off unless config says otherwise,
# because nothing here passes a PreToolUse guard: see provision.sh.
#
# Claude runs this under its 600 s command-hook budget and discards a hook
# that outruns it — no decision, subagent starts anyway. provision.sh's own
# 540 s deadline is therefore the gate that actually holds.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"
cfg_path="$repo/.agents/config.json"

payload="$(cat)"
{ read -r enabled; read -r allow_scripts; } < <(python3 "$lib/config.py" "$cfg_path" \
  hooks.worktree_provision.enabled=true hooks.worktree_provision.allow_scripts=false)
[[ "$enabled" == "yes" ]] || exit 0

{ read -r cwd; read -r project_dir; } < <(printf '%s' "$payload" | python3 -c '
import json, sys
p = json.load(sys.stdin)
print(p.get("cwd") or ""); print(p.get("project_dir") or "")')
[[ -n "$cwd" && -d "$cwd" ]] || exit 0

canon() { ( cd "$1" 2>/dev/null && pwd -P ); }

# The session's own directory is never an isolation worktree, even when the
# operator launched Claude from a linked worktree: installing there would
# rebuild their node_modules under them. project_dir stays at the launch
# directory while an isolated cell's cwd moves under .claude/worktrees/, so
# the two differ exactly for the cells this policy is for.
if [[ -n "$project_dir" && "$(canon "$cwd")" == "$(canon "$project_dir")" && "$cwd" != */.claude/worktrees/* ]]; then
  exit 0
fi

# A linked worktree is one whose private git dir differs from the shared
# one. Compare canonical paths: rev-parse prints the two in different forms
# from a subdirectory, so string equality would misread the main checkout.
gitdir="$(git -C "$cwd" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || exit 0
common="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
[[ "$(canon "$gitdir")" != "$(canon "$common")" ]] || exit 0

top="$(git -C "$cwd" rev-parse --show-toplevel)"

export_scripts=""
[[ "$allow_scripts" == "yes" ]] && export_scripts=1
result="$(PROVISION_ALLOW_SCRIPTS="${export_scripts:-0}" "$repo/.agents/provision.sh" "$top" 2>&1)" || {
  printf '%s\n' "$result" >&2
  exit 2
}

body="Worktree $top — $result. Run tests here; a failure naming a missing module, binary, or runtime version is an environment failure, not a code failure: run .agents/provision.sh . and rerun before touching source."
printf '%s' "$body" | python3 "$lib/emit-context.py" SubagentStart
exit 0

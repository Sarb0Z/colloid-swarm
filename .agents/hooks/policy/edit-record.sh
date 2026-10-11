#!/usr/bin/env bash
# Engine-agnostic policy: record what THIS session wrote, so session-wrap.sh
# measures this session's work rather than every change in a shared tree.
#
# Input (stdin JSON): {"project_dir": "...", "session_id": "...",
#   "transcript_path": "...", "event": "PreToolUse|PostToolUse",
#   "tool_name": "...", "tool_use_id": "...", "files": ["..."],
#   "command": "...", "tool_response": "..."}
# Output: none. A recorder, never a gate: every failure is reported on stderr
# and the hook exits 0.
#
# Files beside session-wrap's state, keyed exactly as it keys its own (cksum of
# session_id, falling back to the transcript path):
#   .agents/.wrap-edits-<key>    `<epoch>\t<path>` per editor-tool write; the
#                                epoch lets the wrap drop a claim the path's
#                                next commit already closed
#   .agents/.wrap-commits-<key>  commits this session made
#   .agents/.wrap-head-<key>-<call>  HEAD and branch before one shell call
# A shell call's commits are whatever HEAD gained during it: PreToolUse
# snapshots HEAD, PostToolUse records `<snapshot>..HEAD` when HEAD moved on the
# same branch. That covers commit, amend, a fixup rebase, cherry-picks, `am` and
# `pull --rebase`, quiet or not; commits already on a remote-tracking branch
# (what a pull brought in) are someone else's and are left out. A call that
# switched branches records nothing. `workloop integrate` moves no HEAD here,
# so its `PASS: integrated … in <workspace>` line records the merged wave: every
# commit the integration branch adds over HEAD.
#
# Claude Code passes a spawned subagent's edits under the parent's session_id
# (observed on 2.1.296), so a cell's work lands in the lead's record. Codex and
# Kimi are unverified — debt: colloid-ui-gate-subagent-session-id
# session-start.sh clears these files on a fresh start; session-wrap.sh reaps
# them after a week.

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="$repo/.agents/hooks/lib"

enabled="$(python3 "$lib/config.py" "$repo/.agents/config.json" hooks.session_wrap.enabled=true)" || {
  echo "edit-record: cannot read the session_wrap toggle; nothing recorded" >&2
  exit 0
}
[[ "$enabled" == "no" ]] && exit 0

payload="$(cat)"
parsed="$(printf '%s' "$payload" | python3 "$lib/payload.py" project_dir session_id transcript_path)" || {
  echo "edit-record: unreadable hook payload; nothing recorded" >&2
  exit 0
}
proj="$(printf '%s\n' "$parsed" | sed -n '1p')"
session_id="$(printf '%s\n' "$parsed" | sed -n '2p')"
transcript="$(printf '%s\n' "$parsed" | sed -n '3p')"
[[ -z "$proj" ]] && proj="$PWD"

# No identity, no file: a record keyed on an empty identity would be one
# repository-wide claim every future session inherits.
ident="${session_id:-$transcript}"
[[ -z "$ident" ]] && exit 0
key="$(printf '%s' "$ident" | cksum | tr -d ' ')"

git -C "$proj" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# The script travels as an argument because stdin carries the payload.
record="$(cat <<'PY'
import json
import os
import re
import subprocess
import sys
import time

proj, key = sys.argv[1], sys.argv[2]
try:
    payload = json.loads(sys.stdin.read() or "{}")
except ValueError:
    payload = {}
if not isinstance(payload, dict):
    payload = {}


def git(*args, cwd=proj):
    result = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ""


def append(path, entries):
    if entries:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as out:
            out.write("".join(entry + "\n" for entry in entries))


top = os.path.realpath(git("rev-parse", "--show-toplevel") or proj)
state_dir = os.path.join(proj, ".agents")

event = payload.get("event") if isinstance(payload.get("event"), str) else ""
call = re.sub(r"[^A-Za-z0-9_-]", "", str(payload.get("tool_use_id") or "")) or "call"
snapshot = os.path.join(state_dir, f".wrap-head-{key}-{call}")


def branch():
    return git("symbolic-ref", "-q", "HEAD")


if event == "PreToolUse":
    head = git("rev-parse", "-q", "--verify", "HEAD")
    if head:
        os.makedirs(state_dir, exist_ok=True)
        with open(snapshot, "w", encoding="utf-8") as out:
            out.write(f"{head}\t{branch()}\n")
    sys.exit(0)

# ── edits ──
now = int(time.time())
lines = []
for name in payload.get("files") or []:
    if not isinstance(name, str) or not name:
        continue
    absolute = os.path.realpath(name if os.path.isabs(name) else os.path.join(proj, name))
    rel = os.path.relpath(absolute, top)
    if rel == "." or rel.startswith(".." + os.sep) or rel == "..":
        continue                                  # outside this repository
    lines.append(f"{now}\t{rel.replace(os.sep, '/')}")
append(os.path.join(state_dir, f".wrap-edits-{key}"), lines)

# ── commits ──
commits = []
try:
    with open(snapshot, encoding="utf-8") as source:
        before, _, before_branch = source.read().strip().partition("\t")
    os.remove(snapshot)
except FileNotFoundError:
    before = ""
if before:
    head = git("rev-parse", "-q", "--verify", "HEAD")
    if head and head != before and branch() == before_branch:
        commits.extend(git("rev-list", "--reverse", f"{before}..HEAD", "--not", "--remotes").split())
command = payload.get("command") if isinstance(payload.get("command"), str) else ""
response = payload.get("tool_response") if isinstance(payload.get("tool_response"), str) else ""
if re.search(r"\bworkloop(?:\.py)?\b[^\n;&|]*\bintegrate\b", command):
    for workspace in re.findall(r"^PASS: integrated .+? in (.+); verify passed$", response, re.M):
        tip = git("rev-parse", "-q", "--verify", "HEAD", cwd=workspace)
        if tip:
            commits.extend(git("rev-list", "--reverse", tip, "--not", "HEAD").split())
try:
    with open(os.path.join(state_dir, f".wrap-commits-{key}"), encoding="utf-8") as existing:
        known = set(existing.read().split())
except FileNotFoundError:
    known = set()
append(os.path.join(state_dir, f".wrap-commits-{key}"), [c for c in dict.fromkeys(commits) if c not in known])
PY
)"
printf '%s' "$payload" | python3 -c "$record" "$proj" "$key" \
  || echo "edit-record: recording failed; this session's wrap falls back to unclaimed files" >&2
exit 0

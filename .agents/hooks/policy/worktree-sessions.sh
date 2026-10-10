#!/usr/bin/env bash
# Claude policy: keep a session that enters a worktree under .claude/worktrees/
# listed by /resume in its repository root. worktree-sessions.py owns the
# behavior; this only hands it the payload.
#
# Input (stdin JSON): {"project_dir", "event", "tool_name", "tool_input", "cwd"}
# Output: a {"systemMessage"} on stdout when a fold kept clashing files aside;
#   folds and expected failures on stderr. Never exit 2: the hook must never
#   stop the session or the EnterWorktree call it rides on. An expected failure
#   exits 0; a defect leaves with Python's traceback and exit 1, which Claude
#   Code reports without blocking.
#
# Opt-in. The switch is hooks.worktree_sessions.enabled in the SESSION
# repository's policy.json and config.json, default off, so a clone of a
# scaffolded repository never has its ~/.claude/projects rearranged unasked.
# An operator who wants it everywhere registers this policy in user settings
# with WORKTREE_SESSIONS_DEFAULT=true: then it runs unless a repository says
# exactly false.

set -euo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
exec python3 "$lib/worktree-sessions.py" hook --default "${WORKTREE_SESSIONS_DEFAULT:-false}"

#!/usr/bin/env python3
"""Refuse a subagent write to the standard that grades its work.

Usage: grader-lock.py <repo>            # payload on stdin
Input  (stdin JSON): {"files": ["<path>", ...]}
Output: exit 2 and one line on stderr when a path is governed; exit 0 otherwise.

The party being graded does not edit its own grader. The policy runs only for
spawned subagents — the adapter's `--agent subagent` selector — so the operator's
own session is never blocked, and an amendment reaches the standard the way the
scaffold already handles every other operator decision: through the main agent.

A subagent may write its work product. A skill is work product: `lint-skills.sh`
grades a skill, and that script is governed here, so the grader stays out of the
graded party's reach while the graded artifact stays writable.

Every path resolves through `realpath` before it is matched. `CLAUDE.md` and
`.claude/settings.json` are symlinks onto canonical files inside the governed
set, so matching the raw path would guard the mirror and miss the file the
mirror points at — and `.agents/AGENTS.md` forbids editing through the mirror
in the first place.

The threat model is an honest mistake by the model, not an adversary with a
shell. This policy sees Edit and Write; `sed -i`, `cat >`, and `python3 -c`
reach the same files unguarded, and `guard-destructive.py` does not stop them.
The lock is a guardrail against writing the rules by accident, never a security
boundary.
"""

import json
import os
import sys

# Everything below one of these is governed: the gates, the transport that
# carries a payload to them, and the harness that grades a review prompt.
GOVERNED_TREES = (
    ".agents/playbooks/",
    ".agents/hooks/",
    ".agents/claude/",
    ".agents/codex/",
    ".agents/eval/",
    # The review harness scores reviewers against these; `ground-truth.md` is the
    # answer key. `eval/review-harness/bin/run-review.sh` already aborts when one
    # merely leaks into the reviewed tree, and editing it beats reading it.
    # This entry and `.agents/eval/` are inert in a satellite: `export-scaffold.py`
    # drops both trees, and a prefix that matches nothing governs nothing.
    ".agents/fixtures/",
    ".kimi/hooks/",
    ".github/workflows/",
)

# Named gates, and the config that can switch one off.
GOVERNED_FILES = (
    ".agents/lint-skills.sh",
    ".agents/sync-claude-agents.sh",
    ".agents/sync-codex.sh",
    ".agents/sync-mcp.sh",
    ".agents/config.json",
    ".agents/config.json.example",
    # Root `AGENTS.md` delegates the scoped-instruction authoring rules here, so
    # this file is one clause of the standard living outside every AGENTS.md.
    ".github/instructions/README.md",
)

# Work product, not the standard. A skill's own AGENTS.md sits under here and is
# therefore writable, which is what keeps ordinary skill work delegable.
SKILLS = ".agents/skills/"


def governed(rel):
    """What the repo-relative path is, or None when a subagent may write it."""
    if rel.startswith(SKILLS):
        return None
    if os.path.basename(rel) == "AGENTS.md":
        return "the standard"
    for tree in GOVERNED_TREES:
        if rel.startswith(tree):
            return "a gate or the transport that reaches one"
    if rel in GOVERNED_FILES:
        return "a gate"
    head, tail = os.path.split(rel)
    if head == ".agents":
        if tail.startswith("test-") and tail.endswith((".sh", ".py")):
            return "the test that proves a gate fires"
        # `toggles.py`, `mcp_registry.py`, `reader_config.py`, `export-scaffold.py`:
        # the modules the sync gates and the session-start policy decide from.
        # `hooks/lib/` is governed for the same reason one level down.
        if tail.endswith(".py"):
            return "the decision logic a gate reads"
    return None


def relative(path, root):
    """Repo-relative POSIX path, or None when the write lands outside the repo.

    `realpath` resolves the symlink mirrors before the match, and resolves the
    root too: a macOS scratch path reaches the hook as /var/... and the tree as
    /private/var/..., which would otherwise read as two different repositories.
    """
    try:
        rel = os.path.relpath(os.path.realpath(path), os.path.realpath(root))
    except (OSError, ValueError):
        return None
    if rel == os.pardir or rel.startswith(os.pardir + os.sep):
        return None
    return rel.replace(os.sep, "/")


REASON = """grader-lock: {rel} is {kind}; a subagent may not write it.

The party being graded does not edit its own grader. State the change you would
make — the exact edit and why it is needed — and return it. The main session
applies it.

Your work product is yours to write, a skill included. The standard, the gates,
the transport that reaches them, and the tests that prove they fire are not."""


def main():
    root = os.path.realpath(sys.argv[1]) if len(sys.argv) > 1 else os.getcwd()
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return 0                            # a blind guard blocks nothing
    if not isinstance(payload, dict):
        return 0
    files = payload.get("files")
    if not isinstance(files, list):
        return 0
    for entry in files:
        if not isinstance(entry, str) or not entry.strip():
            continue
        rel = relative(entry, root)
        if rel is None:
            continue
        kind = governed(rel)
        if kind:
            print(REASON.format(rel=rel, kind=kind), file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

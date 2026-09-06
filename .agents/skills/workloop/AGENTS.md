---
applyTo: '.agents/skills/workloop/**,.claude/skills/workloop/**'
paths:
  - '.agents/skills/workloop/**'
  - '.claude/skills/workloop/**'
---

# Workloop skill rules

- `workloop.py` coordinates evidence and handoffs; it never replaces canonical review reports, breadcrumbs, debt records, or host-specific dispatch.
- Concurrent writing lanes require separate Git worktrees and exclusive repository-relative path ownership. `add-lane` creates and provisions the worktree; a lane commits on its branch before `submit`.
- Do not claim a lane or the run is complete until `check` passes with executable QA evidence; a run with more than one lane also needs a passing, current `integrate`.
- `workloop_git.py` holds every subprocess the controller runs; `workloop.py` holds the state transitions. Keep new git or install steps in the former.

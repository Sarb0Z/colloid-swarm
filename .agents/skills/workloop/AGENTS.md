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
- `workloop_git.py` holds every git, install, and merge subprocess the controller runs and `workloop_docker.py` every docker one. `workloop.py` is the argument parser, `workloop_state.py` the state file and its lock, `workloop_paths.py` path ownership, and `workloop_setup.py`, `workloop_lanes.py`, `workloop_messages.py` and `workloop_finish.py` the commands, by concern. Keep new git or install steps in `workloop_git.py`.

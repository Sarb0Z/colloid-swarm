---
applyTo: '.agents/skills/workloop/**,.claude/skills/workloop/**'
paths:
  - '.agents/skills/workloop/**'
  - '.claude/skills/workloop/**'
---

# Workloop skill rules

- `workloop.py` coordinates evidence and handoffs; it never replaces canonical review reports, breadcrumbs, debt records, or host-specific dispatch.
- Concurrent writing lanes require separate Git worktrees and exclusive repository-relative path ownership. `add-lane` creates and provisions the worktree; a worktree lane commits on its branch before `submit`. A one-writer run's lane (`init --lane`) works in the main checkout, commits on its current branch, and is its run's only lane.
- Do not claim a lane or the run is complete until `check` passes with executable QA evidence; a run with worktree lanes also needs a passing, current `integrate`, and a one-writer run a passing `check` at its accepted commit.
- `workloop_git.py` holds every git, install, and merge subprocess the controller runs and `workloop_docker.py` every docker one. `workloop.py` is the argument parser and `brief`'s choice between a lane and a cell, `workloop_state.py` the state file and its lock, `workloop_paths.py` path ownership, `workloop_main.py` the one-writer run's rules and every run's completion, `workloop_cells.py` read-only cells, `workloop_shared.py` shared paths and their rebuilds, and `workloop_setup.py`, `workloop_lanes.py`, `workloop_messages.py` and `workloop_finish.py` the commands, by concern. Keep new git or install steps in `workloop_git.py`.

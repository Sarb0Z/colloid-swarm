---
applyTo: '.agents/skills/workloop/**,.claude/skills/workloop/**'
paths:
  - '.agents/skills/workloop/**'
  - '.claude/skills/workloop/**'
---

# Workloop skill rules

- `workloop.py` coordinates evidence and handoffs; it never replaces canonical review reports, breadcrumbs, debt records, or host-specific dispatch.
- Concurrent writing lanes require separate Git worktrees and exclusive repository-relative path ownership. `add-lane` creates and provisions the worktree; a worktree lane commits on its branch before `submit`. A one-writer run's lane (`init --lane`) works in the main checkout, commits on its current branch, and is its run's only lane.
- Do not claim a lane or the run is complete until `land` (or `check`) passes with executable QA evidence; a run with worktree lanes also needs a passing, current composition on its source branch's tip, and a one-writer run a passing verify at its accepted commit.
- No controller command removes a lane worktree without first saving its uncommitted work on `refs/workloop/<run>/<lane>/wip` and asking `lost_files` about its ignored files and `nested` about nested repositories; `submit`, `review`, `integrate` and `land` never read that ref.
- `workloop_git.py` holds every git, install, and merge subprocess the controller runs and `workloop_docker.py` every docker one. `workloop.py` is the argument parser and `brief`'s choice between a lane and a cell, `workloop_state.py` the state file, its lock and closed runs' records, `workloop_paths.py` path ownership and the source branch, `workloop_main.py` the one-writer run's rules and every run's completion, `workloop_cells.py` read-only cells, `workloop_shared.py` shared paths and their rebuilds, `workloop_resume.py` the wip ref, `park`, `resume` and the disk floor, `workloop_land.py` `land` and `prune`, and `workloop_setup.py`, `workloop_lanes.py`, `workloop_messages.py` and `workloop_finish.py` the other commands, by concern. Keep new git or install steps in `workloop_git.py`.

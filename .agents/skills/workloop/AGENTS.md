---
applyTo: '.agents/skills/workloop/**,.claude/skills/workloop/**'
paths:
  - '.agents/skills/workloop/**'
  - '.claude/skills/workloop/**'
---

# Workloop skill rules

- `workloop.py` coordinates evidence and handoffs; it never replaces canonical review reports, breadcrumbs, debt records, or host-specific dispatch.
- Concurrent writing lanes require separate Git worktrees and exclusive repository-relative path ownership.
- Do not claim a lane or the run is complete until `check` passes with executable QA evidence.

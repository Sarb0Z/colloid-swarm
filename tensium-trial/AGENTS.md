---
applyTo: 'tensium-trial/**'
paths:
  - 'tensium-trial/**'
---

# Tensium Trial Rules

## Business Invariants
- The metrics in `reference-submission/WRITEUP.md` and the submission `README.md` are receipts, not prose. They must regenerate from the shipped seeds and the documented commands: `verify.sh` for the offline soundness, contamination, and engine receipts; the `analysis.leaderboard_run` command with your own API key for the leaderboard. Do not hand-edit a number.
- The submitted `.zip` archives are the delivered artifact of record. Do not modify or repackage them.

## Abnormal Cases and Rationale
- Files under `analysis/out/` are committed evidence, not build artifacts. If the generator or scorer changes, re-run to regenerate them. A mismatch between the code and a shipped receipt is a defect, not drift to ignore.

## Out of Scope
- This subtree is a frozen trial submission, not scaffold runtime. Do not refactor it to scaffold conventions or wire scaffold hooks or skills into it.

---
applyTo: 'demo/**'
paths:
  - 'demo/**'
---

# Demo Rules

## Business Invariants
- `demo.sh` must resolve the repo root from its own location. It must run from any working directory.
- Every beat must show live output from the real scripts. Mocks and canned output are prohibited.
- Probe payloads for `guard-destructive.sh` must be assembled at runtime. A literal destructive pattern on a command line trips the live session guard.

## Abnormal Cases and Rationale
- The demo presents the membrane it must not trigger. Runtime payload assembly is the safeguard, not a style choice.

## Out of Scope
- Do not restate the beat descriptions in `demo/README.md`. This file governs invariants, not inventory.

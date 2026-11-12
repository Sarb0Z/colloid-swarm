---
applyTo: 'demo/**'
paths:
  - 'demo/**'
---

# Demo Rules

## Business Invariants
- `demo.sh` must resolve the repo root from its own location. It must run from any working directory.
- Every beat must show live output from the real scripts. Mocks and canned output are prohibited.
- Probe payloads for `guard-destructive.sh` reach it as quoted data, never as a command the demo runs. The live session guard matches a command's tokens, not its text.

## Abnormal Cases and Rationale
- The demo presents the membrane it must not trigger. Quoting a pattern is not running it, so the live guard lets the demo through.

## Out of Scope
- Do not restate the beat descriptions in `demo/README.md`. This file governs invariants, not inventory.

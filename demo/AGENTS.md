---
applyTo: 'demo/**'
paths:
  - 'demo/**'
---

# Demo Rules

## Business Invariants
- `demo.sh` must resolve the repo root from its own location. It must run from any working directory.
- Every beat must show live output from the real scripts. Mocks and canned output are prohibited.
- Probe payloads for `guard-destructive.sh` reach it as quoted data, never as a command the demo runs.

## Abnormal Cases and Rationale
- The demo presents the membrane it must not trigger. The live guard reads the command line a session runs and never opens the files that command runs, so `bash demo/demo.sh` passes it. It reads a command's tokens, not its text, so a probe line run by hand passes while its pattern stays quoted.

## Out of Scope
- Do not restate the beat descriptions in `demo/README.md`. This file governs invariants, not inventory.

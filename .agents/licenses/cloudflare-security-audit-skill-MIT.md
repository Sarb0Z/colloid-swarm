# cloudflare/security-audit-skill

Text in the files below is adapted from
https://github.com/cloudflare/security-audit-skill (branch `main`, commit
`c1c8a8c1471069fb0e188eeaff69b8e8db6564a8`) by Cloudflare, Inc., under the MIT
License below. No upstream file is carried whole.

| Local file | Adapted text | Upstream path |
| --- | --- | --- |
| `skills/pentesting/SKILL.md` | The independent verification step: a fresh cell that found nothing tries to refute every candidate, opening "You did not write these candidates. Try to refute each one from repository source and bounded local evidence."; the `confirmed`, `refuted` and `needs_validation` verdicts; severity only on `confirmed` | `skills/security-audit/VALIDATION-AND-REPORTING.md`, `skills/security-audit/SKILL.md` |
| `lenses.md` | The state-machine questions in the Review section's implicit-state-machine lens: skip a step, go backwards, reach an invalid state, replay a completed flow, roll back a partial failure | `skills/security-audit/ATTACK-CLASSES.md` |
| `skills/security-audit/SKILL.md` | "If Layer A prevents the attack, the absence of Layer B is a hardening note"; the high/medium discriminator; the unrated *Needs validation* section; an earlier coverage record never implies the rest is fine | `README.md`, `skills/security-audit/SKILL.md` |

Differences from the source:

- Upstream verifies each candidate in its own cell and records verdicts in a
  schema-validated `findings.json`. `pentesting` sends every candidate to one
  verifier cell and records verdicts in its Markdown report, because its
  reports are read by a person and no pipeline consumes them.
- Upstream's prompt addresses one candidate ("You did not write this
  candidate"); the local prompt addresses the batch.
- Upstream's coverage ledger, quick and scoped modes, and validators are not
  carried. `security-audit` keeps its dated Coverage Log, so the carry-forward
  rule names that log instead of a prior ledger.

## License

```text
MIT License

Copyright (c) 2025-2026 Cloudflare, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

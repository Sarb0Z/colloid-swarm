---
applyTo: '.agents/skills/diagnosing-bugs/**,.claude/skills/diagnosing-bugs/**'
paths:
  - '.agents/skills/diagnosing-bugs/**'
  - '.claude/skills/diagnosing-bugs/**'
---

# Diagnosing-Bugs Skill Rules

## Business Invariants
- This skill is MIT-licensed third-party content. `.agents/licenses/mattpocock-skills-MIT.md` holds its notice, its source commit and every difference from the source. Keep that file while this skill remains, and record each local edit in it.
- `SKILL.md` follows upstream. To change it, prefer an update from upstream that records the new commit. A local fork must be recorded before it lands.
- The root `AGENTS.md` Fix workflow names this skill as its reproduction loop. A change that weakens Phase 1's completion criterion changes the Fix workflow too.

## Abnormal Cases and Rationale
- Phase 3 states the ranked hypotheses in an update and does not wait, where upstream asks the user before testing. The root contract sends the user only blockers that are theirs, and a ranking the session can test is not one.
- Upstream's Redact section and its human-in-the-loop script are not carried: the root contract keeps secret values out of the repository, and its Verify-with-user rule already shapes steps a human runs so one run settles it.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.

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
- The root `AGENTS.md` Fix workflow states Phase 1's first step inline and sends a defect here when no command that goes red can be built, its first run does not make the cause plain, or a fix has failed. The description's Fix clause matches those three conditions; a change to it or to Phase 1 changes the Fix workflow too.

## Abnormal Cases and Rationale
- Phase 3 states the ranked hypotheses in an update and always proceeds, where upstream shows the list to the user and proceeds without an answer only when the user is away. The root contract sends the user only blockers that are theirs, and a ranking the session can test is not one.
- Upstream's human-in-the-loop script is not carried: the root contract's Verify-with-user rule already shapes steps a human runs so one run settles it. Its Redact section is carried, because it governs what the agent shows in transcripts and reports, which the root rule on secrets in the repository does not reach.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.

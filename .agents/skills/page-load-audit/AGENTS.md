---
applyTo: '.agents/skills/page-load-audit/**,.claude/skills/page-load-audit/**'
paths:
  - '.agents/skills/page-load-audit/**'
  - '.claude/skills/page-load-audit/**'
---

# Page-Load-Audit Skill Rules

## Business Invariants
- Keep the body stack-agnostic. Write "CDN", "bundler", "error monitor", "web server". A product or header name may appear only as a parenthetical example, and the step must read correctly with the parenthesis removed.
- Incident figures live in `references/worked-example.md`, never in `SKILL.md`. The method generalises; one system's byte counts and millisecond timings do not, and a number in the body dates the skill.
- Every lever keeps its measure step. A lever without a before-and-after measurement is a guess, and the skill must never present one as a result.
- Every guard the skill introduces ships with a test proven to fail in the guard's absence. A guard without that proof is a comment.
- The skill must never instruct a publish as part of measuring. Source-map upload, push, and deploy are outward mutations; the analysis build suppresses the upload plugin, and the probe for that plugin uses an invalid token against a closed local port.
- Keep the three-state triage table and the hang-versus-refuse table. They are the two places the skill turns a symptom into a checkable question; without them it is advice.

## Abnormal Cases and Rationale
- `references/probes.md` carries runnable scripts on purpose, against the usual preference for prose. The hang-versus-refuse experiment and the cache-stability probe are easy to write subtly wrong (shadowing the global `URL`, a probe change that minification strips), and each was in this skill's own history. The scripts are the corrected versions.
- The frontmatter omits `disable-model-invocation`. A blank-page report is the kind of task an agent should be able to route to this skill unprompted.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.
- Do not duplicate `perf-budget`. That skill gates a metric against a stored baseline; this one finds why the metric is what it is and changes it. Hand off to `perf-budget` to hold the line afterwards.
- Do not carry backend latency or queue saturation. That is `scalability-audit`.

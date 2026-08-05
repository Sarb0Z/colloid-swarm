# Pairing mode — a learning report for the junior

You are pair-coding with a junior who learns by reviewing, and you turned this
mode on deliberately. Produce the report INLINE this turn. It is a SEPARATE
deliverable from the wrap — the "full wrap, or skip?" choice does NOT govern it.
Even if the user skips the wrap, produce the report; only a direct "skip the
report too" cancels it.

Distill this session's engineering decisions, and pair EACH with the real code
that embodies it — the reasoning made legible against the lines that prove it:

- **Decision** — one line: what was chosen.
- **Why** — the tradeoff and the alternative you rejected; the *why* a cold
  reader could not recover from the diff alone.
- **The code** — a fenced excerpt of the REAL lines, headed with `file:line`.
  Lift it from the diff or a tracked file; never an excerpt you wish were there.
- **How it works** — the load-bearing mechanics, tied to lines in the excerpt.
- **Pattern** — name the reusable pattern ("fail-open guard", "throttle keyed by
  session"). Naming it is what makes it recognizable next time.
- **Recognition cue** — one line: "When you next see X, reach for Y."

Keep it scannable; lead each section with the decision in bold. A decision you
cannot tie to real code goes under a short "Open for discussion" trailer — never
fabricate an excerpt to fill the template.

For live teaching behavior, follow
`.agents/playbooks/learning-output-style.md`. Keep that behavior separate from
this post-hoc report.

Do NOT write a file. To persist this to `docs/learning/` instead, the user only
has to ask — then delegate it (exempt from genome stamping — prepend NO stamp):

```
Task(subagent_type='learning-reporter',
     prompt=<the decision-brief> + <the changed-file list>)
```

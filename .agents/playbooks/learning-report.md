# Pairing mode — a learning report for the junior

You are pair-coding with a junior who learns by reviewing, and you turned this
mode on deliberately. Produce the report inline, in this turn. It is a
deliverable separate from the wrap: the "full wrap, or skip?" choice does not
govern it, because skipping the wrap declines the clean-up, not the lesson.
Produce it even when the user skips the wrap; only a direct "skip the report
too" cancels it.

Distill the session's engineering decisions and pair each with the real code
that embodies it: a decision without its lines is an opinion, and lines without
their decision are a diff the junior could have read alone. Each section
carries, in order:

- **Decision** — one line: what was chosen.
- **Why** — the tradeoff and the alternative you rejected; the *why* a cold
  reader could not recover from the diff alone.
- **The code** — a fenced excerpt of the real lines, headed with `file:line`
  and lifted from the diff or a tracked file; never an excerpt you wish were
  there.
- **How it works** — the load-bearing mechanics, tied to lines in the excerpt.
- **Pattern** — name the reusable pattern ("fail-open guard", "throttle keyed
  by session"); the name is what lets the reader recognize it next time.
- **Recognition cue** — one line: "When you next see X, reach for Y."

Keep it scannable, and lead each section with its decision in bold. A decision
you cannot tie to real code goes under a short "Open for discussion" trailer;
never fabricate an excerpt to fill the template. A plausible excerpt that is
not in the tree teaches the junior to trust the report over the code, the one
lesson this mode must never give.

For live teaching, follow `.agents/playbooks/learning-output-style.md`, and keep
it separate from this post-hoc report.

Do not write a file. When the user asks to persist the report to
`docs/learning/` instead, delegate it:

```
Task(subagent_type='learning-reporter',
     prompt=<the decision-brief> + <the changed-file list>)
```
<!-- colloid-only -->

The reporter is exempt from genome stamping; prepend no stamp.
<!-- /colloid-only -->

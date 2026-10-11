# Pairing mode — a learning report for the junior

You are pair-coding with a junior who learns by reviewing, and you turned this
mode on deliberately. The report is written inline, in this turn, and is a
deliverable separate from the wrap: the "full wrap, or skip?" choice does not
govern it. A user who skips the wrap still gets the report; only a direct
"skip the report too" cancels it.

Distill the session's engineering decisions and pair each with the real code
that embodies it, so the reasoning reads against the lines that prove it. Each
section carries, in order:

- **Decision** — one line: what was chosen.
- **Why** — the tradeoff and the alternative you rejected; the *why* a cold
  reader could not recover from the diff alone.
- **The code** — a fenced excerpt of the real lines, headed with `file:line`
  and lifted from the diff or a tracked file; never an excerpt you wish were
  there.
- **How it works** — the load-bearing mechanics, tied to lines in the excerpt.
- **Pattern** — the reusable pattern, named ("fail-open guard", "throttle keyed
  by session"); the name is what lets the reader recognize it next time.
- **Recognition cue** — one line: "When you next see X, reach for Y."

The report stays scannable, each section led by its decision in bold. A
decision that ties to no real code goes under a short "Open for discussion"
trailer; no excerpt is fabricated to fill the template.

Live teaching follows `.agents/playbooks/learning-output-style.md` and stays
separate from this post-hoc report.

No file is written unless the user asks for one; the report then goes to
`docs/learning/` by delegation:

```
Task(subagent_type='learning-reporter',
     prompt=<the decision-brief> + <the changed-file list>)
```
<!-- colloid-only -->

The reporter is exempt from genome stamping; its prompt carries no stamp.
<!-- /colloid-only -->

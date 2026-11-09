# google/elephant-goldfish-model

Two rules in `.agents/playbooks/hostile-review.md`, in the paragraph on how
the lead dispositions findings, are adapted from
https://github.com/google/elephant-goldfish-model (branch `main`, commit
`5382b17619be07811a14b2146c7672620b34a791`), under the Apache License,
Version 2.0. Its README states "This is not an officially supported Google
product." No upstream file is carried whole, and upstream ships no NOTICE
file and names no copyright holder in its files.

| Adapted rule | Upstream text | Upstream path |
| --- | --- | --- |
| A decline cites evidence the reviewer can check; "this was intentional" is not evidence | "A contest must be checkable. 'This was intentional' is not evidence." | `skills/egm-resolve/SKILL.md` |
| A reviewer that errors, stops early, or returns no report has not run | "Never count it as a reviewer with zero findings." | `skills/egm-review-loop/SKILL.md` |

Changes from the source: the rules are reworded for this repository's lead
and reviewer cells. Upstream escalates a finding whose evidence lies outside
every file the reviewer could read; here only a fact neither the lead nor the
reviewer can check goes to the user, because the lead settles what the session
can check itself. Upstream's rule that an applied fix does not settle a finding
is not carried: it conflicts with the rule that a `P2` fix does not reopen a
round.

The full Apache License 2.0 text is at
`.agents/licenses/learning-output-style-APACHE-2.0.txt` and at
https://www.apache.org/licenses/LICENSE-2.0.

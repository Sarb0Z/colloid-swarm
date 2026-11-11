# Plan research

The facts a plan rests on are gathered before the plan is written, into one
findings table, and the plan states as fact only the rows marked `observed`.
<!-- colloid-only -->
Plans that state something false about the existing code, files or systems
were the class reviewers reported most across the fleet's review logs
(`knowledge/research/2026-11-11-fleet-session-logs-mined-for-harness-ideas.md`).
<!-- /colloid-only -->

## Who writes it

At Standard stakes the lead writes it. At Critical stakes a fresh read-only
cell that never saw the conversation writes it: a generic cell on the medium
tier with a shell, or `explorer` for a question bounded to a few files it can
answer by opening lines. External claims, such as a vendor's API or a price, go
to `researcher` cells, which keep their own source and confidence rules. The
lead re-opens the cited lines of every row the riskiest step rests on and lists
those rows under the table as `Re-opened by the lead: F2, F5`.

## The table

Above the table, the commit it was read at (`git rev-parse --short HEAD`) and
any uncommitted change to the files it cites (`git status --short -- <paths>`),
since a row read from the working tree is true of that tree, not of the commit.

| # | Claim | Evidence | Status |
|---|---|---|---|
| F1 | One fact the plan will act on, stated so it could be false | `path:line` opened; or the command run and the part of its output that shows the claim; or a URL and the date it was read | `observed` |

- `observed`: the line was opened, or the command run, in the tree above.
- `inferred`: reasoned from observed rows and not itself seen.
- `not read`: needed and not yet checked.

Below the table, two short lists: **Constraints**, what the plan cannot change,
each citing its row; **Open questions**, what a probe or the operator must
settle. One page at most: cut a row the plan does not act on.

## Using it

- The table sits in the plan document, above the plan, so the plan's reviewer
  opens the same lines.
- The plan cites rows by number. A claim it needs that is `inferred` or `not
  read` becomes a spike in the plan, a probe whose result decides the step, or
  a question to the operator; the plan never states it as fact.
- Before implementation starts, list the cited files that changed since the
  table was read, working tree included (`git diff --stat <commit> -- <paths>`);
  each of their rows returns to `not read` until its lines are opened again.

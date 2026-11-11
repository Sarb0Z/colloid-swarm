# Plan research

The facts a plan rests on are gathered before the plan is written, into one
findings table, and the plan states as fact only the rows marked `observed`.
Plans that state something false about the existing code, files or systems
were the class reviewers reported most across the fleet's review logs
(`knowledge/research/2026-11-11-fleet-session-logs-mined-for-harness-ideas.md`).

## Who writes it

At Standard stakes the lead writes it. At Critical stakes a fresh read-only
cell that never saw the conversation writes it: `explorer` for rows answered by
opening lines, a generic research cell with a shell on the medium tier for rows
that need a command run. The lead checks the rows the riskiest step rests on.

## The table

Above the table, the commit it was read at (`git rev-parse --short HEAD`).

| # | Claim | Evidence | Status |
|---|---|---|---|
| F1 | One fact the plan will act on, stated so it could be false | `path:line` opened; or the command run and the part of its output that shows the claim; or a URL and the date it was read | `observed` |

- `observed`: the line was opened, or the command run, at the commit above.
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
- Before implementation starts, re-check every row whose file changed since
  the commit read at (`git diff --stat <commit> HEAD -- <paths>`), and update
  its status.

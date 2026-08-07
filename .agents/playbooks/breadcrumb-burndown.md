# Breadcrumb burndown

`breadcrumbs.md` is a queue. A queue that only grows is a list, and the
SessionStart hook shows ten of it. This playbook drains the queue.

Run it when the operator asks, or when the count has grown for several sessions
with nothing coming out. It is its own unit of work with its own budget — never
fold it into the change that happened to add the last line.

## Open with the count

```sh
grep -c '^- ' .agents/breadcrumbs.md
```

That number is the receipt, before and after. Report both. A burndown that
cannot state what it removed did not happen.

## Classify every line

Read the whole file once. Give each line exactly one disposition, with one line
of reasoning. Classify from the line alone — a breadcrumb states its own case,
and opening the code for all of them costs more than the queue is worth. Open
the code only for what you are about to fix.

| Disposition | Meaning | Where it goes |
|---|---|---|
| **Fix now** | Bounded work, and the line still describes the tree | Its own change; the line comes out with the fix |
| **Convert** | Not work but a standing tradeoff — a condition, a trigger, a rework cost | A `### <id>` entry in `debt-log.md`; the line comes out |
| **Delete** | Already done, no longer true, or refused | Straight out, with the reason in the burndown report |
| **Escalate** | The line names an open operator decision | Stays, and the report asks the question |

Three of these remove the line. "Escalate" is the only disposition that leaves
one behind, and it must carry the question the operator has to answer — a line
that has been re-read for months without a question attached is a **delete**,
not an escalation.

A line that would be fixed but is not bounded is not a fix — convert it, or
escalate it. Do not leave it as a breadcrumb with a note.

## One fix, one change

Every **fix now** ships as its own change with its own verification. A burndown
that lands twelve unrelated fixes in one commit cannot be reviewed and cannot be
reverted. The line comes out in the same change as the fix, never before it.

## A pattern across lines indicts a rule

Several lines describing the same defect in different places are not N fixes.
Name the rule, the missing test, or the shape that produced them, fix that, and
close every line it covers in one change that cites the cause. Recurring
breadcrumbs are the cheapest evidence the scaffold generates about itself:
group the file by the path each line names, and a path holding many lines is
describing a shape rather than a backlog.

## Close with the count

Report the starting count, the count now, and the per-disposition tally, each
from a command. Then state what is left and why — the escalations, with their
questions. An operator reading only the last paragraph must learn what they now
have to decide.

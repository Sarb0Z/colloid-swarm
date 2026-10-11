# Work log

The work log is the agent's own working record of what the day changed. Keep it
current; it is not a report written in the user's name, and the rule that a
deliverable leaving the repository stands alone does not apply to it.

`session-start.sh` names today's file when `hooks.worklog.enabled` is `true` in
`.agents/config.json`. `hooks.worklog.dir` empty keeps it at
`.agents/worklog/YYYY-MM-DD.md`, which Git ignores; a folder beside the
repository holds it there instead, once the operator grants write access.

## When

Update today's file after each major change: a feature unit, a fix round, a
migration, a deploy, a decision that changes what a customer experiences. One
file per working day, named `YYYY-MM-DD.md`; amend it as the day goes on rather
than starting a second one.

## Sections

| Section | Contains |
|---|---|
| Summary | A status table, then the few items with real consequence for customers or the business |
| Work completed | Per item: what it was, what changed, the outcome for a customer or the business, the deliverable |
| Findings | What a customer or the business experiences because of each finding, technical detail after |
| Needs a decision | One row per open question with a named owner, mirroring the entry that holds it |

Close with one line of verification state: the suites run and their result,
the build, and what was not checked.

## Rules

- Lead with the outcome. "An order can be charged twice when the customer
  retries checkout" comes before the function that causes it; file-and-line
  detail follows the outcome.
- Record results, not the journey. Dead ends and revised assumptions stay out
  of the log and out of code comments; rationale that must persist goes to
  `.agents/decisions.md`. The one exception is a wrong conclusion someone may
  still act on: state the correct fact where that decision gets made.
- The log holds no state of its own. An open question lives in
  `.agents/breadcrumbs.md` and a settled one in `.agents/decisions.md`; the
  "Needs a decision" rows mirror those entries and never hold one alone.
- No forward plan and no artifact index; deferred work goes to
  `.agents/breadcrumbs.md`.
- Never write a secret, a credential, or a customer's personal data into the log.

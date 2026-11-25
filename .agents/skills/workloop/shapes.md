# One example per delegation shape

Each example answers the guide's six questions in `SKILL.md`, then shows the
dispatch. Briefs are abridged to their fields; a writing or QA cell's brief
also carries `working-practice.md` verbatim. For a lane, `brief` writes the
brief to `.workloop/BRIEF.md` in its worktree and prints a two-line dispatch
prompt (the header, then the path to read); that prompt is what the lead
dispatches.

## Contents

- One writer
- Read-only fan-out
- Parallel slices
- Contract-first split
- Bake-off

## One writer

*Add a CSV export to the reports page.* It changes files (1); one writer can
do it (2), so the shape stops there. Tier: medium. Around it: one read-only
cell traces how the page loads its data, before the writer starts.

```text
READ-ONLY. Trace how apps/web/src/pages/reports loads its rows: the query,
its parameters, and the type of a row. Return file:line references, no edits.
```

```text
Objective: the reports page exports its current rows as CSV, so finance can
reconcile without copying by hand.
Owns: apps/web/src/pages/reports/**, its tests. Must not touch: the API.
Acceptance: pnpm vitest run apps/web/src/pages/reports
Returns: RESULT / ACCEPTANCE / BOUNDARY.
Stop and report if: the export needs a new API field.
<working-practice.md>
```

The writer edits the main tree as a one-writer run. The lead records it with
one command, which prints the prompt to dispatch:

```sh
.agents/workloop.py init export --objective 'Reports export their rows as CSV' \
  --acceptance 'pnpm vitest run apps/web/src/pages/reports passes' \
  --verify 'pnpm vitest run apps/web' \
  --lane csv --worker implementer --path apps/web/src/pages/reports
```

The tracing cell joins the same run, before the writer starts; its printed
prompt, with the question above appended below it, is what the lead dispatches:

```sh
.agents/workloop.py add-cell export trace --role research --model haiku
.agents/workloop.py returned export trace --result reply   # when it comes back
```

After the writer submits: `brief export csv --role reviewer` for the reviewer
and `brief export csv --role qa` for QA, dispatched together, then `qa` once QA
is back, `check` (it runs `--verify` once at the accepted commit), `teardown`.

## Read-only fan-out

*Which hosted queue fits the ingest service?* Nothing changes (1). Three
cells, one question each, at the light or medium tier by how much judgement
each needs:

```text
READ-ONLY. Research: pricing and limits of SQS, Cloud Tasks and Upstash QStash
at 2M messages a month. Return a table with sources and dates.
```

```text
READ-ONLY. Research: delivery guarantees and retry semantics of the same three.
```

```text
READ-ONLY. Trace where services/ingest enqueues today and what it assumes
about ordering. Return file:line references.
```

The run declares no `--verify`, since nothing is tested, and records each
cell; append each question above below its printed prompt:

```sh
.agents/workloop.py init queue --objective 'Pick a hosted queue for ingest' \
  --acceptance 'a recommendation backed by the three returns'
.agents/workloop.py add-cell queue pricing --role research --model sonnet
.agents/workloop.py add-cell queue delivery --role research --model sonnet
.agents/workloop.py add-cell queue current --role research --model haiku
# as each comes back:
.agents/workloop.py returned queue pricing --result reply
```

Once all three are back, `check queue` passes and `teardown queue` closes the
run. The lead keeps the synthesis.

`--result reply` records the word and keeps no text. When the lead will quote or
cite a report, or a later reader must check it, run
`.agents/workloop.py save-reply queue pricing` first: it copies the cell's final
report out of its agent's transcript, byte for byte, to
`.agents/worktrees/queue/.workloop/replies/pricing-<agent id>.txt`, which the
closed run keeps, and then `returned queue pricing --result <that file>` records
it. Name a file in the work itself with `--to <file>` when the report belongs
there, as a research project's evidence does; `--to` is required for a closed
run. The command accepts a cell in any state, changes no state, and replaces a
file holding other content only with `--force`; a cell dispatched again keeps
its first report. It refuses a cell that ended its turn to wait on a command of
its own. Retyping a report into a file paraphrases it without a trace.

## Parallel slices

*Add audit logging to billing and to accounts.* Two disjoint folders that merge
in any order (3), two writers:

```sh
.agents/workloop.py init audit --objective 'Billing and accounts write audit rows' \
  --acceptance 'each service test asserts its audit row' \
  --verify 'pnpm test --filter services'
.agents/workloop.py add-lane audit billing --worker implementer --path services/billing
.agents/workloop.py add-lane audit accounts --worker implementer --path services/accounts
.agents/workloop.py brief audit billing --role worker
.agents/workloop.py brief audit accounts --role worker
```

Dispatch each printed prompt as its cell's prompt, then review both lanes in one round
with the QA cell dispatched beside the reviewer, `qa`, `integrate`, `check`, `teardown`.

## Contract-first split

*An API returns claim summaries; the web app shows them.* The web lane consumes
what the API lane produces (4). Fix the interface first, and commit it:

```sh
git add packages/contracts/claim-summary.ts packages/contracts/fixtures/claim-summary.json
git commit -m 'feat(contracts): claim summary shape for the API and the web app'
.agents/workloop.py init summaries --objective 'Claim summaries from API to screen' \
  --acceptance 'API test returns the fixture shape; web test renders the fixture' \
  --verify 'pnpm test' --shared package.json
.agents/workloop.py share summaries pnpm-lock.yaml --rebuild 'pnpm install --lockfile-only'
.agents/workloop.py add-lane summaries api --worker implementer --path services/api
.agents/workloop.py add-lane summaries web --worker implementer --path apps/web
```

`init` pins the base after the contract commit, so both lanes start with it
and build at once. Either lane may add a dependency: Git merges `package.json`,
and `integrate` re-locks `pnpm-lock.yaml` once from the base's copy instead of
merging two lockfiles. Below each printed prompt, append the lane's part:

```text
Contract: packages/contracts/claim-summary.ts and fixtures/claim-summary.json,
committed at the run's base. Build against it; never edit it.
Returns: RESULT / ACCEPTANCE / BOUNDARY.
Stop and report if: the contract cannot carry what this lane needs.
```

The consumer tests against the fixture. A change to the contract stops both
lanes and comes back to the lead.

## Bake-off

*Two caching designs both look right for the search endpoint.* The choice is
worth paying for twice (5), so ask for designs, not builds:

```text
READ-ONLY. Design request-level caching for GET /search in services/api:
keys, invalidation on write, memory bound. Return the design, every path by
which a read can be stale after a write, its memory bound at 1M documents,
and the files it would touch. Selection: no stale read after a write, then
the smaller memory bound, then fewer files touched.
```

```text
READ-ONLY. Design result caching for GET /search in the database layer
(materialised view or table): refresh, staleness, storage. Same return and
selection rule.
```

The selection rule judges what a design states, so the lead can apply it
before anything is built, then dispatch one writer for the winner. A rule
that needs a measurement, such as p95 latency, needs builds: two writers
building both designs cost two full builds and two reviews, so do that only
when the designs cannot be judged without running them.

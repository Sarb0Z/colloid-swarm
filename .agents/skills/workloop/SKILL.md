---
name: workloop
description: Designs each delegation before dispatch, choosing among one writer, a read-only fan-out, parallel slices, a contract-first split and a bake-off, and coordinates writing lanes through a portable, evidence-backed controller.
---

# Workloop

Read this before dispatching more than one cell toward one objective. The
guide below picks the delegation's shape; the controller then coordinates the
writing lanes the shape needs.

## Choose the shape

Answer six questions about the work. The answers pick a shape; shapes combine,
and you may depart from them by stating why.

1. **Does it change files?** No: a **read-only fan-out** — research, review or
   QA cells that return text. Three cells by default, up to about ten for broad
   research, each with one distinct question. Each prompt opens `READ-ONLY`.
   The run is `init` without `--verify` and one `add-cell` per cell (below).
2. **Can one writer do it in reasonable time?** Yes: **one writer**, with
   read-only cells around it. This is the default; most delegations are this.
   The writer edits the main tree as a one-writer run: one `init … --lane`
   records the run and its lane and prints the dispatch line (below).
3. **Do the parts touch disjoint files and merge in any order?** Yes:
   **parallel slices**, one lane each. At most about three writers on one
   codebase unless you state why more pay off; the controller's ceiling of
   eight is the backstop.
4. **Does one part consume an interface another produces?** Yes: a
   **contract-first split**. Commit the contract (types, a schema, sample data)
   before `init`, so the run's base holds it; the producer and consumer lanes
   then build against it at once. A lane added with `--depends-on` cannot
   claim until that lane is reviewed, so use it only where the consumer needs
   the producer's code, not just its contract.
5. **Is the choice between approaches worth paying for several times?** Only
   then a **bake-off**: every attempt costs its full tokens and time. Prefer
   read-only cells that return competing designs to writers that each build
   one, keep it to two or three, and decide the selection rule before
   dispatch.
6. **Which tier does each cell need?** The tier follows how hard the cell's own
   task is, by the root contract's tiers, not the stakes of the whole job.

Each lane carries one behaviour, at most one migration, and merges within
about a day. A part riskier than its neighbours is its own lane, built after
the parts it rests on are reviewed. The lead's digest names a lane past 800
changed lines in its paths, one owning more than 15 paths, one widened a second
time, and a run open over a day while its default branch moved; it refuses
nothing, and its remedy is to split what remains into a new lane once this one
is reviewed.

Weigh each shape's cost:

- A read-only cell costs its tokens only.
- The lone writer adds nothing to the checkout while it works; its `check`
  makes one short-lived worktree and install at the accepted commit.
- Each extra writer adds a worktree, an install, a review and a merge:
  measured 2026-10-13 on real disk, about 6 s and 0.26 GB per lane on the
  scaffold, 7 s and 0.24 GB on `food-app-core`, 12 s and 0.9 GB on `claims-app`.
- A bake-off pays every attempt in full.

Every brief states:

- the objective and why it matters;
- what the cell owns, and what it must not touch;
- the contract it builds against, if any;
- the narrowest acceptance it runs;
- what it returns, and in what shape;
- when to stop and report instead of widening;
- for a writing or QA cell, the working practice in `working-practice.md`
  (how it tests, starts servers, waits and edits).

For a lane, `brief` writes the run's objective and acceptance, the lane's
owned paths, and the working practice to `<lane worktree>/.workloop/BRIEF.md`
(`BRIEF-reviewer.md` and `BRIEF-qa.md` for those roles; git ignores the folder,
and every `brief` call rewrites the file, so a widened lane gets a current one).
A one-writer run's lane has no worktree: its briefs go to
`.agents/worktrees/<run>/.workloop/<lane>.md` (`-reviewer`, `-qa`). It prints a
dispatch prompt: the header line, then one line naming that file for the cell
to read first; a reviewer or QA prompt opens with a `READ-ONLY` line, so the
writers gate does not count that cell. A worktree lane's `brief` writes into its
worktree, so it fails after `teardown` or a failed `add-lane`. Paste the prompt unchanged as the cell's prompt, and
append the lane's own objective, its contract, what it returns and when it
stops below it, leaving the header line first: the parallel-writers gate
recognises a lane cell by that line. A cell outside a run gets a brief you write: paste
`working-practice.md` into a generic cell's prompt, while `implementer` and
`qa-verifier` carry it already. `shapes.md` shows one worked example per
shape.

## The controller

The controller is a portable coordination surface, not an agent launcher. The
lead dispatches the generated briefs through the current host and delivers any
`attention` output to the named cell. The controller records only workflow state
and references to canonical review artifacts: findings remain in hostile-review
reports, unresolved work in `breadcrumbs.md`, accepted tradeoffs in
`debt-log.md`.

`--supervised` opts explicitly into peer coordination; it is no hook and leaves
the ordinary workflow unchanged. A host with direct agent messaging or
resumable agents delivers the same messages and restart requests natively;
elsewhere the cells poll the durable inbox at each handoff.

## Start a run

A lone writer is a one-writer run: one command before the dispatch, five after
the cell submits.

```sh
.agents/workloop.py init export --objective 'Reports export their rows as CSV' \
  --acceptance 'the reports page test downloads the visible rows' \
  --verify 'pnpm vitest run apps/web' \
  --lane csv --worker implementer --path apps/web/src/pages/reports
# dispatch the printed prompt; the cell claims, commits on the current branch, submits
.agents/workloop.py brief export csv --role reviewer   # dispatch; it accepts with --tip
.agents/workloop.py check export      # runs --verify once, at the accepted commit
.agents/workloop.py qa export --evidence '<observed result>'
.agents/workloop.py check export && .agents/workloop.py teardown export
```

The lane works in the main checkout on its current branch: no worktree, branch
or install. Its cell stages by path (`git add -- <path>`), since others may
hold uncommitted work in the checkout. Its work is the commits since its first
claim that touch its paths; another writer's commits there are listed, not
refused, and so is a commit touching its paths and others ("mixed"), for the
reviewer to judge. `add-lane` refuses a run holding such a lane: writers working
at once start a run with worktree lanes. `check` tests the accepted commit in a
short-lived worktree at `.agents/worktrees/<run>/verify`, removed after a pass
and kept for inspection after a fail; a lane-path commit or uncommitted edit
after the accept makes the run stale until the lane is re-submitted.

## Read-only cells

Every cell of a multi-cell delegation belongs to its run, the read-only ones
too, so the run shows what was dispatched and what came back. A cell takes no
worktree, branch or install:

```sh
.agents/workloop.py add-cell export trace --role research --model haiku
# dispatch the printed prompt; when it comes back:
.agents/workloop.py returned export trace --result reply
```

`add-cell <run> <name> --role research|review|qa --model <model>` records the
cell as out and prints its dispatch prompt: a `READ-ONLY` line, the header
`WORKLOOP CELL BRIEF — <run>/<name>`, then the brief to read, at
`.agents/worktrees/<run>/.workloop/cells/<name>.md`. Append the cell's question
below the prompt, never above it: the gate reads `READ-ONLY` only as the first
line, and the prompt tells the cell its question follows. The cell returns its result as its reply and writes no file;
`returned --result <path>` names a file the lead wrote from it instead of
`reply`; a relative path reads from the working directory and is stored
absolute. `returned <run> <name> --failed '<reason>'` records a cell that died
or was stopped, and `brief <run> <name> --again` sends a returned or failed
cell out again. `status` and the lead's digest list cells still out; `check`,
`teardown` and the session end will not close the run while one is, though
`check` still runs a one-writer run's composed test and names `returned` for
each, and `integrate` does not wait for them. A torn-down run takes no cell.
No cell outlives its session, so a cell
still out at a startup or resume is named with `--failed` or `--again`, unless
another live session leads its run; a compaction or `/clear` ends no cell.

A lane's own review stays `brief <run> <lane> --role reviewer`, which names
the commits and the `review --tip` handoff; a review cell is for what is not a
lane, such as a plan. A run started without `--verify` is a read-only fan-out:
it is finished once every cell is back, with no QA record and no composed test,
so `qa` and `integrate` say there is nothing for them, and `add-lane` refuses it. When a writer will follow the cells, start with
`init … --lane` instead and add the cells beside it. The lead's digest names a
turn that dispatched two or more cells with no run header ("3 cells last turn
outside any run"); it refuses nothing.

`--model <model>` on `add-lane` or `init --lane` records a lane's model, shown
in its brief and in `status`.

For writers working at once, create one run with a testable objective, the test
command proving the composed result, and a base revision, which `init` pins to
a commit. Add a lane
per writer: `add-lane` creates the worktree on branch `<run>/<lane>` when the
path does not exist, installs its dependencies from the lockfiles, and records
the lockfile hash. A writing lane owns exclusive paths.

```sh
.agents/workloop.py init slice-3b --objective 'Persist parsed 835 claims' \
  --acceptance 'database, parser, and browser scenarios pass' \
  --verify 'pnpm test --filter api' --base HEAD --supervised
.agents/workloop.py add-lane slice-3b persistence --worker implementer \
  --path apps/api --path tests/api
.agents/workloop.py brief slice-3b persistence --role worker
```

A lane's worktree lives at `.agents/worktrees/<run>/<lane>` inside the
checkout; `--workspace <path>` places it elsewhere, but never under `/tmp`,
which the system clears. `.gitignore` hides `.agents/worktrees/` from
`git status` and `rg`, and `add-lane` warns where it does not. A test runner
that walks the tree without honouring `.gitignore`, such as an unanchored
vitest or jest glob, finds every lane's copy of the tests: when a repository's
first run starts, check the runner's discovery roots. A Claude Code cell the
lead dispatches from the main checkout runs that checkout's guards and reads
the run state there; a Codex session, or a Claude session launched inside a
lane, uses the lane's own copy of the scaffold.

`widen <run> <lane> --path <p>` gives a running lane another owned path, and
`--also <dir>` adds a directory to a sparse lane's cone and checks it out. It
refuses only a path another lane owns or one that overlaps a shared path, and
prints what changed.

Lanes are full checkouts. Add `--sparse` only on a very large monorepo: the
worktree then holds the owned directories, the root files, any `--also <dir>`,
and what the install needs, read from the base commit: the folders holding
`patchedDependencies` patches (from `package.json` or `pnpm-workspace.yaml`) and
every JavaScript workspace member (`workspaces`, `pnpm-workspace.yaml`), which
`add-lane` prints as `cone + <dir> (<why>)`. Workspaces of uv, Cargo and go are
not read; their own install fails loudly when a member is missing. It refuses,
naming each file and the `--also <dir>` that fixes it, when the cone would drop
a lockfile that `provision.sh` installs in a full checkout (a root lockfile
makes nested ones of its ecosystem irrelevant). It refuses, telling you to drop
`--sparse`, when a workspace pattern uses more than `*`, `**`, a leading `!` and
a leading `./`; when a positive pattern matches no folder holding a
`package.json`; and when `pnpm-workspace.yaml` has a `packages:` or
`patchedDependencies:` shape it cannot read. Name the review directory in the cone, because git refuses
to stage a file outside it, and any directory the tests import from. A directory
absent at the base is created empty. The integration worktree is always full.

Some files every lane changes: a manifest, service wiring, a doc index, a
lockfile, generated code. Declare each as shared, with `init --shared <path>`
(repeatable) at the start or `share <run> <path>` at any point. A lane cannot
own a shared path (`add-lane` and `share` refuse any overlap), and any lane may
edit one: `submit` accepts changes to shared paths, and dirty shared work
blocks `submit` and `integrate` like owned work. Each shared path has one of
two rules:

- **Merged** (the default: manifests, indexes, READMEs). Git merges the lanes'
  edits at `integrate`; lanes append and never reorder. A conflict stops
  `integrate` naming the lanes, the paths, and the remedy: rebase the later
  lane onto the earlier one's branch, resolve it there, and re-submit. A lane
  rebases onto one branch only, so one conflicting with several merged lanes
  drops or defers the edits that overlap the others.
- **Rebuilt** (`share <run> <path> --rebuild '<command>'`: lockfiles, generated
  code). Lanes change and commit it to test in their worktrees; `integrate`
  takes the base's copy in every lane merge, so lockfiles never conflict, then
  runs each rebuild command once over the merged tree, in the order the paths
  were shared and before any install, and commits the result when it changed.
  Rebuild commands run outside every hook, so prefer forms that re-lock
  without installing or running package scripts (`uv lock`,
  `pnpm install --lockfile-only`,
  `npm install --package-lock-only --ignore-scripts`). A command that needs
  installed packages installs them itself, scripts off
  (`pnpm install --ignore-scripts && pnpm gen`). A lane re-locks the same
  way, then runs provision: a full install in a lane whose `node_modules` is
  linked from the checkout writes into the checkout. A rebuild that fails,
  times out, or changes a path outside the rebuilt ones stops `integrate`.
  A rebuild path may sit inside a merged one (`share web`, then
  `share web/package-lock.json --rebuild …`), never the reverse, since the
  merged file would be reset with it. `--rebuild ''` clears the command; a
  one-writer run takes none, since it merges nothing.

A `share` after lanes start reaches them only through a fresh brief: it prints
the `brief` command for each claimed lane not yet reviewed. A `share` after `integrate` makes the
integration stale until it runs again. A sparse lane receives a shared
directory only through `--also`. A lane may rebase onto a
sibling in `review` or `reviewed`; `submit` measures its changes from where
its own commits begin, so the sibling's files do not count against it, but
only while the sibling's work stays inside its own paths. `integrate` measures
each lane again against the siblings' current branches, and refuses one whose
branch moved after its accepted review: `submit` it again. It
merges in dependency order.

```sh
.agents/workloop.py init slice-3b --objective '...' --acceptance '...' \
  --verify 'uv run pytest' --shared pyproject.toml --shared docs/index.md
.agents/workloop.py share slice-3b uv.lock --rebuild 'uv lock'
```

`--verify` must be a test command. `init` refuses one the destructive or publish
rules would refuse — a floor, not a review — and the floor holds even where
`config.json` switches those hooks off, because `integrate` runs the command
unattended with no hook in front of it. Give it no cleaning or resetting step:
`integrate` already resets the worktree to the base and cleans
it before merging, and such a step is exactly what the floor refuses.

Use the prompt `brief` prints as the bounded dispatch prompt. The cell claims the lane, works only in
its worktree and declared paths, commits on the lane branch, and submits observed
test evidence. `claim` refuses a lane whose lockfiles changed since it
was provisioned, or whose install failed, until `provision <run> <lane>`
succeeds; a test failure naming a missing module, binary, or runtime version is
that case, not a code defect. `submit` refuses uncommitted work, because review
and integration read the branch. Review can begin from the brief in parallel,
but final acceptance comes only once the submitted diff and its canonical
review report are available.

## Resources a lane starts

Three lanes sharing one Postgres, one Docker daemon, and one machine's browser
capacity are bottlenecked, not stalled, and a lane killed mid-run leaves its
containers behind. The controller answers with ownership, leases, and progress:

- **Ownership.** The brief exports `COLLOID_RUN`, `COLLOID_LANE`, and
  `COMPOSE_PROJECT_NAME=<run>-<lane>`. What only a lane uses carries
  `--label colloid.run=<run> --label colloid.lane=<lane>` or that compose
  project name; what the run shares — the one Postgres — carries `colloid.run`
  alone, so a lane's reap never takes it and `teardown` does. `release-stale`,
  `teardown`, and `reap` remove by those labels, report what docker refused,
  and touch nothing else. The lead's digest reaps a lane whose cell stopped
  without submitting (the hook records every cell's start and stop) and names,
  without removing, test containers that belong to no one — a testcontainers
  session with no reaper. A container a test framework starts under its own
  labels lies outside all this: leave that framework's reaper on.
- **Leases.** `add-lane --exclusive <name>` leases a resource only one active
  lane may hold — `playwright`, a device, a shared service that cannot be
  copied. `claim` refuses while another active lane holds it; the lead
  sequences dispatch, and nothing queues. The lease frees at `submit` or
  `release-stale`; what the holder started stays until `reap` or `teardown`.
  `status` shows each lane's lease, so a misspelt name is visible.
- **Cheap isolation.** One shared, labelled Postgres per run and a database per
  lane named from `COLLOID_LANE` (the shape Rails uses per test worker), not a
  container per lane; give a lane its own compose stack only when it needs one.
- **Progress.** `heartbeat --progress '<what is running>'` works on any claimed
  lane, and the digest and `status` show it beside the lane's age, so a slow
  lane reads as slow.
- **Narrow acceptance.** A lane runs only the narrowest acceptance for its slice,
  never the end-to-end or browser suite; `--verify` runs once over the result:
  at `integrate` for a run with worktree lanes, one or more, and at `check` for
  a one-writer run. Every merge queue works this way.

## Feedback and recovery

The reviewer records `accept` or `reopen` with a canonical report reference: a
path in the repository, or the absolute path of any existing file, such as a
report written in another project. An accept names the commit it reviewed,
`--tip <sha>`, which the reviewer brief prints; it is refused when the lane
moved past that commit, so the lane re-submits and the new commits are
reviewed. For
a P0 or a path conflict, the lead runs `attention`, delivers the printed prompt,
and records the cell's acknowledgement before the correction cycle.

```sh
.agents/workloop.py attention slice-3b persistence --severity P0 \
  --message 'Path ownership conflicts with ingest lane.' --reference '<existing-review-report>#p0'
.agents/workloop.py ack slice-3b persistence --agent persistence-worker
```

**One review round per wave.** A multi-lane wave gets one review round that
reads every lane's diff; `brief --role reviewer` writes each lane's start point
and the `git diff <start>..<lane-branch>` command. Each lane's `review` cites
its section of the one report. A P2 finding is filed, never reopened:
`review --result reopen` takes `--severity P0` or `P1` explicitly, and a P2
there, or an `attention --severity P2` on a lane in review, is refused, so
accept the lane and file it. Submissions are counted, so an attention,
acknowledgement, and resubmit counts too. A review of a fourth submission is
refused unless
`review --ruling "<operator's words>"` is given, and the ruling is stored in the
review ref; this is deliberately stricter than the playbook's same-shape rule.

`release-stale` makes an interrupted claim resumable, erasing neither evidence nor
a pending attention item.

## Peer messages and supervision

In a supervised run, a reviewer or peer sends a compact, referenced message to
the recipient lane. A message that requires acknowledgement blocks
that lane's next submission, QA, and completion until the recipient's current
claimant acknowledges it, and the sender cannot acknowledge its own message.

```sh
.agents/workloop.py send slice-3b --from-lane parser --to-lane persistence \
  --agent parser-worker --kind finding --message 'Validate duplicate claim IDs.' \
  --reference docs/reviews/slice-3b.md#duplicate-ids --requires-ack
.agents/workloop.py inbox slice-3b persistence
.agents/workloop.py ack-message slice-3b persistence <message-id> --agent persistence-worker
.agents/workloop.py heartbeat slice-3b persistence --agent persistence-worker
.agents/workloop.py watch slice-3b --stale-seconds 900
```

Under Claude, `workloop-inbox.sh` delivers these without polling: a cell hears
its host agent id at start and each unread message for its lane once between
tool calls, and the lead hears at every prompt which lanes await review, carry
attention, are stale or broken or growing past their size, and each run's next
closing step: `integrate`, `check`, QA, or `teardown`. The same hook stamps each
background lane and cell with the time and its last tool call, at most once a
minute, so `status` shows every agent's time out, its silence and its last action
without the agent reporting anything. A hook cannot wake an idle lead, so when
agents are still out as your turn ends, schedule the loop:
`/loop 10m .agents/workloop.py watch <run>`. Each pass, post
`.agents/workloop.py digest <run>` when it differs from the last one you
posted, and end the loop when `.agents/workloop.py check <run>` passes. On Codex and
Kimi the manual `inbox` stands.

`watch` is read-only and reports O(lanes + messages) work. Its restart request
must be delivered by a native host adapter or a lead; it never claims to restart or
interrupt an agent itself. A run retains at most 128 messages by default.
Archive acknowledgement-free status and evidence-ready chatter before that
ceiling. An acknowledged finding is dropped once the lane it addresses is
reviewed; one awaiting acknowledgement is never archived, and it blocks
completion until the claimant answers it.

```sh
.agents/workloop.py archive slice-3b
```

## Integrate and tear down

Each lane verified its own slice in its own worktree; nothing has verified the
composition. Once every lane is reviewed, `integrate` resets an integration
worktree (`.agents/worktrees/<run>/integration` unless `--workspace` names
one) to the base on branch `<run>/integration`, merges the lane branches in
dependency order, provisions, and runs the `--verify` command once. A conflict
aborts the merge, names the two lanes, and leaves the tree clean for the rerun.
On a run with worktree lanes, `check` requires a passing integration whose
recorded lane tips still match; a lane commit after integration reports
`integration:stale` until `integrate` reruns.

```sh
.agents/workloop.py integrate slice-3b
.agents/workloop.py qa slice-3b --evidence 'Playwright and service tests passed'
.agents/workloop.py check slice-3b
.agents/workloop.py teardown slice-3b
```

`teardown` removes the lane and integration worktrees once `check` passes. It
deletes a branch only when the repository's HEAD already contains it; the
`<run>/integration` branch carries the verified composition, so land it first
and rerun `teardown` to drop it.

`abandon <run>` closes a run whose work landed another way — after main moved
past the base, for instance, so that `integrate` and `teardown` refuse. It reaps
the run's labelled containers, removes the lane and integration worktrees, and
deletes the run from state. It deletes only branches the repository's HEAD
already contains and names the rest; `--discard-branches` deletes those too.
When the run's checkout is not on disk, git cannot read it, or git reads it as
part of an enclosing repository (an empty mount point), `abandon` refuses with
git's reason, because a disk that is not mounted looks the same as a deleted
checkout, and the session-end sweep runs `abandon` unattended. Mount or repair
the checkout and rerun. If it was deleted, remove any folder left at its path
and rerun with `--checkout-gone`. A main checkout that still holds the run's
branches or worktrees, as a deleted linked worktree's does, is found through
the state file or a surviving lane folder, and the release goes through it.
Otherwise only the run's containers are reaped, and every lane and integration
folder recorded outside the checkout is named: one on disk holds the only copy
left of its work.

## Complete the cycle

Only the independent QA result advances the run. `check` is the completion
gate: it fails when any lane is unresolved, lacks evidence, or has
unacknowledged attention, when the run lacks QA evidence, or when its composed
test has no current pass: an integration for worktree lanes, a verification at
the accepted commit for a one-writer run. `check --recorded` judges from what is
recorded and never runs the test; the session end uses it.

The default ceiling is eight lanes; each further lane requires `--allow-more`
when added, so the lead accepts the coordination cost deliberately.

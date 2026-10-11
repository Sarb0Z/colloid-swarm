---
name: workloop
description: Coordinates durable, bounded parallel implementation and review lanes through a portable evidence-backed controller.
---

# Workloop

Use it for long-running work with two or more independent implementation
lanes, parallel reviewer feedback, or a handoff that must survive compaction, never
for a small, one-shot edit.

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

Create one run with a testable objective, the test command proving the composed
result, and a base revision, which `init` pins to a commit. Add a lane
per writer: `add-lane` creates the worktree on branch `<run>/<lane>` when the
path does not exist, installs its dependencies from the lockfiles, and records
the lockfile hash. A writing lane owns exclusive paths.

```sh
.agents/workloop.py init slice-3b --objective 'Persist parsed 835 claims' \
  --acceptance 'database, parser, and browser scenarios pass' \
  --verify 'pnpm test --filter api' --base HEAD --supervised
.agents/workloop.py add-lane slice-3b persistence --worker implementer \
  --workspace ../claims-app-persistence --path apps/api --path tests/api
.agents/workloop.py brief slice-3b persistence --role worker
```

On a large or vendored repository add `--sparse`, and the lane's worktree then
holds only its owned directories, the root files, and any `--also <dir>`. Name
the review directory there, because git refuses to stage a file outside the
cone, and any directory the tests import from. A directory absent at the base is
created empty in the cone. Lockfiles outside the cone are not installed, and a
root pnpm workspace whose packages fall outside the cone installs partially and
reports success, so give such a lane the whole workspace. The integration
worktree is always full.

`--verify` must be a test command. `init` refuses one the destructive or publish
rules would refuse — a floor, not a review — and the floor holds even where
`config.json` switches those hooks off, because `integrate` runs the command
unattended with no hook in front of it. Give it no cleaning or resetting step:
`integrate` already resets the worktree to the base and cleans
it before merging, and such a step is exactly what the floor refuses.

Use `brief` as the bounded dispatch prompt. The cell claims the lane, works only in
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
  never the end-to-end or browser suite; `integrate` runs `--verify` once over
  the merged tree. Every merge queue works this way.

## Feedback and recovery

The reviewer records `accept` or `reopen` with a canonical report reference. For
a P0 or a path conflict, the lead runs `attention`, delivers the printed prompt,
and records the cell's acknowledgement before the correction cycle.

```sh
.agents/workloop.py attention slice-3b persistence --severity P0 \
  --message 'Path ownership conflicts with ingest lane.' --reference '<existing-review-report>#p0'
.agents/workloop.py ack slice-3b persistence --agent persistence-worker
```

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
attention, are stale or broken, and when a run is ready to integrate. A hook
cannot wake an idle lead, so for a run that outlives the lead's turn, schedule
the poll: `/loop 10m .agents/workloop.py watch <run>`. On Codex and Kimi the manual
`inbox` stands.

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
worktree to the base on branch `<run>/integration`, merges the lane branches in
dependency order, provisions, and runs the `--verify` command once. A conflict
aborts the merge, names the two lanes, and leaves the tree clean for the rerun.
On a run with more than one lane, `check` requires a passing integration whose
recorded lane tips still match; a lane commit after integration reports
`integration:stale` until `integrate` reruns.

```sh
.agents/workloop.py integrate slice-3b --workspace ../claims-app-integration
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

## Complete the cycle

Only the independent QA result advances the run. `check` is the completion
gate: it fails when any lane is unresolved, lacks evidence, or has
unacknowledged attention, when the run lacks QA evidence, or when a multi-lane
run lacks a current passing integration.

The default ceiling is eight lanes; each further lane requires `--allow-more`
when added, so the lead accepts the coordination cost deliberately.

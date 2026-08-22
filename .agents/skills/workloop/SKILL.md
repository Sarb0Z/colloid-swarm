---
name: workloop
description: Coordinates durable, bounded parallel implementation and review lanes through a portable evidence-backed controller.
---

# Workloop

Use for long-running work with two or more independent implementation lanes,
parallel reviewer feedback, or a handoff that must survive compaction. Do not
use it for a small, one-shot edit.

The controller is a portable coordination surface, not an agent launcher. The
lead dispatches the generated briefs through the current host and delivers any
`attention` output to the named worker. It records only workflow state and
references to canonical review artifacts; findings remain in hostile-review
reports, unresolved work remains in `breadcrumbs.md`, and accepted tradeoffs
remain in `debt-log.md`.

`--supervised` is an explicit opt-in for peer coordination. It is not a hook
and does not change the ordinary workflow. On hosts with direct agent messaging
or resumable agents, deliver the same messages and restart requests natively;
otherwise agents poll the durable inbox at each handoff.

## Start a run

Create one run with a testable objective and an explicit base revision. Add a
lane per isolated Git worktree; a writing lane owns exclusive paths.

```sh
.agents/workloop.py init slice-3b --objective 'Persist parsed 835 claims' \
  --acceptance 'database, parser, and browser scenarios pass' --base HEAD --supervised
.agents/workloop.py add-lane slice-3b persistence --worker implementer \
  --workspace ../clearclaim-persistence --path apps/api --path tests/api
.agents/workloop.py brief slice-3b persistence --role worker
```

Use `brief` as the bounded dispatch prompt. The worker claims the lane, works
only in its worktree and declared paths, then submits observed test evidence.
Review can begin from the brief in parallel, but final acceptance occurs only
after the submitted diff and its canonical review report are available.

## Feedback and recovery

The reviewer records `accept` or `reopen` with a canonical report reference.
For a P0 or path conflict, the lead runs `attention`, delivers the printed
prompt, and records the worker acknowledgement before the correction cycle.

```sh
.agents/workloop.py attention slice-3b persistence --severity P0 \
  --message 'Path ownership conflicts with ingest lane.' --reference '<existing-review-report>#p0'
.agents/workloop.py ack slice-3b persistence --agent persistence-worker
```

`release-stale` makes an interrupted claim resumable. It does not erase
evidence or a pending attention item.

## Peer messages and supervision

In a supervised run, a reviewer or peer sends a compact, referenced message
directly to the recipient lane. An acknowledgement-required message blocks that
lane's next submission, QA, and completion until the recipient's current
claimant acknowledges it. The sender cannot acknowledge its own message.

```sh
.agents/workloop.py send slice-3b --from-lane parser --to-lane persistence \
  --agent parser-worker --kind finding --message 'Validate duplicate claim IDs.' \
  --reference docs/reviews/slice-3b.md#duplicate-ids --requires-ack
.agents/workloop.py inbox slice-3b persistence
.agents/workloop.py ack-message slice-3b persistence <message-id> --agent persistence-worker
.agents/workloop.py heartbeat slice-3b persistence --agent persistence-worker
.agents/workloop.py watch slice-3b --stale-seconds 900
```

`watch` is read-only and reports O(lanes + messages) work. Its restart request
must be delivered by a native host adapter or a lead; it never claims to restart
or interrupt an agent itself. A run retains at most 128 messages by default.
Archive acknowledged-free status and evidence-ready chatter before that ceiling;
required findings remain until their review cycle is complete.

```sh
.agents/workloop.py archive slice-3b
```

## Complete the cycle

Only the independent QA result advances the run. `check` is the completion
gate: it fails if any lane is unresolved, lacks evidence, has unacknowledged
attention, or the run lacks QA evidence.

```sh
.agents/workloop.py qa slice-3b --evidence 'Playwright and service tests passed'
.agents/workloop.py check slice-3b
```

The default ceiling is eight lanes. More lanes require `--allow-more` when
adding the next lane, so the lead consciously accepts the added coordination
cost.

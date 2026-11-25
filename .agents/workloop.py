#!/usr/bin/env python3
"""Durable, provider-neutral coordination for bounded parallel agent work.

This file is the command line: the argument parser that routes each command to
its handler. The state file, its lock and closed runs' records live in
workloop_state.py, path ownership in workloop_paths.py, and the handlers in
workloop_setup.py, workloop_lanes.py, workloop_shared.py, workloop_cells.py,
workloop_messages.py, workloop_finish.py, workloop_land.py (land, prune) and
workloop_resume.py (park, resume, the wip ref and the disk floor).
"""

from __future__ import annotations

import argparse
import functools
import re
import time

from workloop_cells import cell_brief, cells_of, cmd_add_cell, cmd_returned, cmd_save_reply
from workloop_finish import (
    cmd_abandon,
    cmd_check,
    cmd_integrate,
    cmd_qa,
    cmd_reap,
    cmd_teardown,
)
from workloop_land import cmd_land, cmd_prune
from workloop_resume import cmd_park, cmd_resume
from workloop_lanes import (
    cmd_ack,
    cmd_attention,
    cmd_claim,
    cmd_heartbeat,
    cmd_release_stale,
    cmd_review,
    cmd_status,
    cmd_submit,
    dispatch_prompt,
)
from workloop_messages import (
    cmd_ack_message,
    cmd_archive,
    cmd_digest,
    cmd_inbox,
    cmd_send,
    cmd_watch,
)
from workloop_paths import WORKTREES, temporary, workspace_for
from workloop_setup import SHAPES, cmd_add_lane, cmd_init, cmd_provision, cmd_widen
from workloop_shared import cmd_share
from workloop_state import ReadStore, fail, run_of, state_path

# workloop_state put the hooks' library on the path.
import agent_dismissals  # noqa: E402
import agent_effects  # noqa: E402
from workloop_size import GitBudget  # noqa: E402

# test-workloop.sh imports these two from here.
__all__ = ["parser", "temporary", "workspace_for"]


def cmd_brief(args: argparse.Namespace) -> None:
    """A lane's role brief, or a cell's prompt: lanes and cells share one namespace per run."""
    with ReadStore(state_path(args.state)) as data:
        run = run_of(data, args.run)
    if args.lane in cells_of(run):
        cell_brief(args, run)
        return
    if args.lane not in run["lanes"]:
        fail(f"run has no lane or cell named {args.lane!r}")
    if args.again:
        fail(f"--again sends a returned or failed cell out again; {args.lane!r} is a lane, whose brief prints without it")
    print(dispatch_prompt(state_path(args.state), args.run, run, args.lane, run["lanes"][args.lane], args.role or "worker"))


def cmd_dismiss(args: argparse.Namespace) -> None:
    """Stop showing a dead agent of this checkout at every start and prompt (agent_dismissals.py)."""
    state = state_path(args.state)
    agents_dir = state.parent
    if not re.fullmatch(r"[A-Za-z0-9]+", args.agent):
        fail(f"{args.agent!r} is no agent id: an AGENT DIED line names it, letters and digits only")
    try:
        died = agent_effects.death_at(state, args.agent, GitBudget().out)
        dismissals = agent_dismissals.dismissed(agents_dir)
    except ValueError as error:
        fail(str(error))
    if died is None and args.agent in dismissals:
        print(f"agent {args.agent} is dismissed already")
        return
    if died is None:
        fail(f"no agent {args.agent} touched this checkout and died; its AGENT DIED line names the id to dismiss")
    if agent_dismissals.covers(dismissals, args.agent, died):
        print(f"agent {args.agent} is dismissed already")
        return
    try:
        agent_dismissals.dismiss(agents_dir, args.agent, died, args.reason, time.time())
    except ValueError as error:
        fail(str(error))
    print(f"dismissed agent {args.agent}'s death; later starts and prompts no longer show it unless it dies again")


def parser() -> argparse.ArgumentParser:
    # No abbreviations: `--rul` must not mean `--ruling`, which the authority
    # hook refuses from cells by its full spelling.
    root = argparse.ArgumentParser(epilog=SHAPES, formatter_class=argparse.RawDescriptionHelpFormatter, allow_abbrev=False)
    root.add_argument("--state", help="state file (default: .agents/.workloop-state.json)")
    root.add_argument("--event-id", help="idempotency key for a mutating command")
    sub = root.add_subparsers(required=True, parser_class=functools.partial(argparse.ArgumentParser, allow_abbrev=False))
    init = sub.add_parser("init"); init.add_argument("run"); init.add_argument("--objective", required=True); init.add_argument("--acceptance", required=True); init.add_argument("--verify", help="the composed test: check runs it in a worktree at a main lane's accepted commit, integrate over the merged tree for worktree lanes; a run declared without it is a read-only fan-out, which holds cells only"); init.add_argument("--repo", help="checkout the run belongs to (default: the current directory's)"); init.add_argument("--base", default="HEAD"); init.add_argument("--shared", action="append", help="repository path every lane may edit without owning it (repeatable)"); init.add_argument("--max-lanes", type=int, default=8); init.add_argument("--supervised", action="store_true"); init.add_argument("--message-limit", type=int, default=128); init.add_argument("--lane", help="one writer: the run's sole lane, working in the checkout itself; prints its dispatch"); init.add_argument("--worker", help="the main lane's worker type (with --lane)"); init.add_argument("--path", action="append", help="a path the main lane owns (with --lane, repeatable)"); init.add_argument("--model", help="the main lane's model, printed in its brief and in status (with --lane)"); init.set_defaults(func=cmd_init)
    add = sub.add_parser("add-lane"); add.add_argument("run"); add.add_argument("lane"); add.add_argument("--worker", required=True); add.add_argument("--workspace", help=f"the lane's worktree (default: {WORKTREES}/<run>/<lane> in the checkout)"); add.add_argument("--path", action="append", required=True); add.add_argument("--depends-on", action="append"); add.add_argument("--allow-more", action="store_true"); add.add_argument("--sparse", action="store_true", help="very large monorepos only: check out the owned directories, --also ones, and what the install needs"); add.add_argument("--also", action="append", help="extra directory to include in a sparse cone"); add.add_argument("--exclusive", action="append", help="a named resource only one active lane may hold, e.g. playwright"); add.add_argument("--model", help="the lane's model, printed in its brief and in status"); add.set_defaults(func=cmd_add_lane)
    widen = sub.add_parser("widen"); widen.add_argument("run"); widen.add_argument("lane"); widen.add_argument("--path", action="append", help="repository path the lane comes to own (repeatable)"); widen.add_argument("--also", action="append", help="directory added to a sparse lane's cone (repeatable)"); widen.set_defaults(func=cmd_widen)
    share = sub.add_parser("share", help="declare a repository path every lane may edit without owning it, optionally rebuilt once at integrate"); share.add_argument("run"); share.add_argument("path"); share.add_argument("--rebuild", help="command that regenerates the path (a lockfile, generated code): lane merges take the path from the base and integrate runs this once over the merged tree before the install; '' clears it"); share.set_defaults(func=cmd_share)
    claim = sub.add_parser("claim"); claim.add_argument("run"); claim.add_argument("lane"); claim.add_argument("--agent", required=True); claim.set_defaults(func=cmd_claim)
    submit = sub.add_parser("submit"); submit.add_argument("run"); submit.add_argument("lane"); submit.add_argument("--evidence", required=True); submit.set_defaults(func=cmd_submit)
    review = sub.add_parser("review"); review.add_argument("run"); review.add_argument("lane"); review.add_argument("--reference", required=True); review.add_argument("--result", choices=("accept", "reopen"), required=True); review.add_argument("--severity", choices=("P0", "P1", "P2"), help="required with --result reopen"); review.add_argument("--tip", help="required with --result accept: the commit the review read, as the reviewer brief names it"); review.add_argument("--ruling", help="the operator's words authorising a review after the lane's fourth reopen verdict"); review.add_argument("--message", default="review requested a correction"); review.set_defaults(func=cmd_review)
    attention = sub.add_parser("attention"); attention.add_argument("run"); attention.add_argument("lane"); attention.add_argument("--severity", choices=("P0", "P1", "P2"), required=True); attention.add_argument("--message", required=True); attention.add_argument("--reference", default=""); attention.set_defaults(func=cmd_attention)
    ack = sub.add_parser("ack"); ack.add_argument("run"); ack.add_argument("lane"); ack.add_argument("--agent", required=True); ack.set_defaults(func=cmd_ack)
    stale = sub.add_parser("release-stale"); stale.add_argument("run"); stale.add_argument("lane"); stale.add_argument("--reason", required=True); stale.set_defaults(func=cmd_release_stale)
    qa = sub.add_parser("qa"); qa.add_argument("run"); qa.add_argument("--evidence", required=True); qa.set_defaults(func=cmd_qa)
    check = sub.add_parser("check"); check.add_argument("run"); check.add_argument("--recorded", action="store_true", help="judge from recorded results only; never run the composed test"); check.set_defaults(func=cmd_check)
    provision = sub.add_parser("provision"); provision.add_argument("run"); provision.add_argument("lane"); provision.set_defaults(func=cmd_provision)
    integrate = sub.add_parser("integrate"); integrate.add_argument("run"); integrate.add_argument("--workspace", help=f"the integration worktree (default: {WORKTREES}/<run>/integration in the checkout)"); integrate.set_defaults(func=cmd_integrate)
    teardown = sub.add_parser("teardown"); teardown.add_argument("run"); teardown.set_defaults(func=cmd_teardown)
    land = sub.add_parser("land", help="put a finished run's work on its source branch in this checkout, verified there, and close it; never pushes"); land.add_argument("run"); land.set_defaults(func=cmd_land)
    park = sub.add_parser("park", help="save a lane's uncommitted work on refs/workloop/<run>/<lane>/wip and remove its worktree"); park.add_argument("run"); park.add_argument("lane"); park.set_defaults(func=cmd_park)
    resume = sub.add_parser("resume", help="re-add each lane worktree that is gone at its branch tip and restore its saved work"); resume.add_argument("run"); resume.set_defaults(func=cmd_resume)
    prune = sub.add_parser("prune", help="delete closed runs' records from .agents/worktrees/.closed/"); prune.add_argument("--closed-before", required=True, help="a date (2026-11-25) or UTC time; records of runs closed before it go"); prune.set_defaults(func=cmd_prune)
    abandon = sub.add_parser("abandon"); abandon.add_argument("run"); abandon.add_argument("--discard-branches", action="store_true", help="also delete lane branches whose commits HEAD does not contain"); abandon.add_argument("--checkout-gone", action="store_true", help="the run's checkout was deleted: reap its containers, name the folders it leaves, and drop the run without git"); abandon.set_defaults(func=cmd_abandon)
    add_cell = sub.add_parser("add-cell", help="record a read-only cell: no worktree, branch or install; prints its dispatch"); add_cell.add_argument("run"); add_cell.add_argument("name"); add_cell.add_argument("--role", choices=("research", "review", "qa"), required=True); add_cell.add_argument("--model", required=True); add_cell.set_defaults(func=cmd_add_cell)
    returned = sub.add_parser("returned", help="a cell came back, or did not"); returned.add_argument("run"); returned.add_argument("name"); outcome = returned.add_mutually_exclusive_group(required=True); outcome.add_argument("--result", help="where its result went: a file the lead wrote, or the word reply"); outcome.add_argument("--failed", help="why it died or was stopped without returning"); returned.set_defaults(func=cmd_returned)
    save_reply = sub.add_parser("save-reply", help="save a cell's final report word for word from its agent's transcript, then record the file with returned --result"); save_reply.add_argument("run"); save_reply.add_argument("name"); save_reply.add_argument("--to", help="the file to write; a closed run needs it (default: .agents/worktrees/<run>/.workloop/replies/<cell>.txt)"); save_reply.add_argument("--force", action="store_true", help="replace a file that holds other content"); save_reply.set_defaults(func=cmd_save_reply)
    brief = sub.add_parser("brief"); brief.add_argument("run"); brief.add_argument("lane", help="a lane or a cell"); brief.add_argument("--role", choices=("worker", "reviewer", "qa"), help="a lane's brief: worker (default), reviewer or qa; a cell's role is set at add-cell"); brief.add_argument("--again", action="store_true", help="send a returned or failed cell out again, tracked until it returns"); brief.set_defaults(func=cmd_brief)
    status = sub.add_parser("status"); status.add_argument("run"); status.set_defaults(func=cmd_status)
    send = sub.add_parser("send"); send.add_argument("run"); send.add_argument("--from-lane", required=True); send.add_argument("--to-lane", required=True); send.add_argument("--agent", required=True); send.add_argument("--kind", choices=("finding", "blocked", "evidence-ready", "status"), required=True); send.add_argument("--message", required=True); send.add_argument("--reference", default=""); send.add_argument("--requires-ack", action="store_true"); send.set_defaults(func=cmd_send)
    inbox = sub.add_parser("inbox"); inbox.add_argument("run"); inbox.add_argument("lane"); inbox.set_defaults(func=cmd_inbox)
    ack_message = sub.add_parser("ack-message"); ack_message.add_argument("run"); ack_message.add_argument("lane"); ack_message.add_argument("message_id"); ack_message.add_argument("--agent", required=True); ack_message.set_defaults(func=cmd_ack_message)
    beat = sub.add_parser("heartbeat"); beat.add_argument("run"); beat.add_argument("lane"); beat.add_argument("--agent", required=True); beat.add_argument("--progress", help="what the lane is doing right now"); beat.set_defaults(func=cmd_heartbeat)
    reap = sub.add_parser("reap"); reap.add_argument("run"); reap.add_argument("--lane"); reap.set_defaults(func=cmd_reap)
    watch = sub.add_parser("watch"); watch.add_argument("run"); watch.add_argument("--stale-seconds", type=int, default=900); watch.set_defaults(func=cmd_watch)
    digest = sub.add_parser("digest", help="one line per lane and cell: name, role, state, silence, last action"); digest.add_argument("run"); digest.set_defaults(func=cmd_digest)
    archive = sub.add_parser("archive"); archive.add_argument("run"); archive.set_defaults(func=cmd_archive)
    dismiss = sub.add_parser("dismiss", help="stop showing a dead agent's AGENT DIED line, with the reason"); dismiss.add_argument("agent", help="the agent id its AGENT DIED line names"); dismiss.add_argument("--reason", required=True); dismiss.set_defaults(func=cmd_dismiss)
    return root


if __name__ == "__main__":
    args = parser().parse_args()
    args.func(args)

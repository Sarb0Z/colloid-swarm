#!/usr/bin/env python3
"""Durable, provider-neutral coordination for bounded parallel agent work.

This file is the command line: the argument parser that routes each command to
its handler. The state file and its lock live in workloop_state.py, path
ownership in workloop_paths.py, and the handlers in workloop_setup.py,
workloop_lanes.py, workloop_messages.py and workloop_finish.py.
"""

from __future__ import annotations

import argparse

from workloop_finish import (
    cmd_abandon,
    cmd_check,
    cmd_integrate,
    cmd_qa,
    cmd_reap,
    cmd_teardown,
)
from workloop_lanes import (
    cmd_ack,
    cmd_attention,
    cmd_brief,
    cmd_claim,
    cmd_heartbeat,
    cmd_release_stale,
    cmd_review,
    cmd_status,
    cmd_submit,
)
from workloop_messages import (
    cmd_ack_message,
    cmd_archive,
    cmd_inbox,
    cmd_send,
    cmd_watch,
)
from workloop_paths import WORKTREES, temporary, workspace_for
from workloop_setup import SHAPES, cmd_add_lane, cmd_init, cmd_provision, cmd_widen

# test-workloop.sh imports these two from here.
__all__ = ["parser", "temporary", "workspace_for"]


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(epilog=SHAPES, formatter_class=argparse.RawDescriptionHelpFormatter)
    root.add_argument("--state", help="state file (default: .agents/.workloop-state.json)")
    root.add_argument("--event-id", help="idempotency key for a mutating command")
    sub = root.add_subparsers(required=True)
    init = sub.add_parser("init"); init.add_argument("run"); init.add_argument("--objective", required=True); init.add_argument("--acceptance", required=True); init.add_argument("--verify", help="test command run once over the composed tree by integrate"); init.add_argument("--repo", help="checkout the run belongs to (default: the current directory's)"); init.add_argument("--base", default="HEAD"); init.add_argument("--shared", action="append", help="repository path every lane may edit without owning it (repeatable)"); init.add_argument("--max-lanes", type=int, default=8); init.add_argument("--supervised", action="store_true"); init.add_argument("--message-limit", type=int, default=128); init.set_defaults(func=cmd_init)
    add = sub.add_parser("add-lane"); add.add_argument("run"); add.add_argument("lane"); add.add_argument("--worker", required=True); add.add_argument("--workspace", help=f"the lane's worktree (default: {WORKTREES}/<run>/<lane> in the checkout)"); add.add_argument("--path", action="append", required=True); add.add_argument("--depends-on", action="append"); add.add_argument("--allow-more", action="store_true"); add.add_argument("--sparse", action="store_true", help="very large monorepos only: check out the owned directories, --also ones, and what the install needs"); add.add_argument("--also", action="append", help="extra directory to include in a sparse cone"); add.add_argument("--exclusive", action="append", help="a named resource only one active lane may hold, e.g. playwright"); add.set_defaults(func=cmd_add_lane)
    widen = sub.add_parser("widen"); widen.add_argument("run"); widen.add_argument("lane"); widen.add_argument("--path", action="append", help="repository path the lane comes to own (repeatable)"); widen.add_argument("--also", action="append", help="directory added to a sparse lane's cone (repeatable)"); widen.set_defaults(func=cmd_widen)
    claim = sub.add_parser("claim"); claim.add_argument("run"); claim.add_argument("lane"); claim.add_argument("--agent", required=True); claim.set_defaults(func=cmd_claim)
    submit = sub.add_parser("submit"); submit.add_argument("run"); submit.add_argument("lane"); submit.add_argument("--evidence", required=True); submit.set_defaults(func=cmd_submit)
    review = sub.add_parser("review"); review.add_argument("run"); review.add_argument("lane"); review.add_argument("--reference", required=True); review.add_argument("--result", choices=("accept", "reopen"), required=True); review.add_argument("--severity", choices=("P0", "P1", "P2"), help="required with --result reopen"); review.add_argument("--ruling", help="the operator's words authorising a review round past the third submission"); review.add_argument("--message", default="review requested a correction"); review.set_defaults(func=cmd_review)
    attention = sub.add_parser("attention"); attention.add_argument("run"); attention.add_argument("lane"); attention.add_argument("--severity", choices=("P0", "P1", "P2"), required=True); attention.add_argument("--message", required=True); attention.add_argument("--reference", default=""); attention.set_defaults(func=cmd_attention)
    ack = sub.add_parser("ack"); ack.add_argument("run"); ack.add_argument("lane"); ack.add_argument("--agent", required=True); ack.set_defaults(func=cmd_ack)
    stale = sub.add_parser("release-stale"); stale.add_argument("run"); stale.add_argument("lane"); stale.add_argument("--reason", required=True); stale.set_defaults(func=cmd_release_stale)
    qa = sub.add_parser("qa"); qa.add_argument("run"); qa.add_argument("--evidence", required=True); qa.set_defaults(func=cmd_qa)
    check = sub.add_parser("check"); check.add_argument("run"); check.set_defaults(func=cmd_check)
    provision = sub.add_parser("provision"); provision.add_argument("run"); provision.add_argument("lane"); provision.set_defaults(func=cmd_provision)
    integrate = sub.add_parser("integrate"); integrate.add_argument("run"); integrate.add_argument("--workspace", help=f"the integration worktree (default: {WORKTREES}/<run>/integration in the checkout)"); integrate.set_defaults(func=cmd_integrate)
    teardown = sub.add_parser("teardown"); teardown.add_argument("run"); teardown.set_defaults(func=cmd_teardown)
    abandon = sub.add_parser("abandon"); abandon.add_argument("run"); abandon.add_argument("--discard-branches", action="store_true", help="also delete lane branches whose commits HEAD does not contain"); abandon.set_defaults(func=cmd_abandon)
    brief = sub.add_parser("brief"); brief.add_argument("run"); brief.add_argument("lane"); brief.add_argument("--role", choices=("worker", "reviewer", "qa"), default="worker"); brief.set_defaults(func=cmd_brief)
    status = sub.add_parser("status"); status.add_argument("run"); status.set_defaults(func=cmd_status)
    send = sub.add_parser("send"); send.add_argument("run"); send.add_argument("--from-lane", required=True); send.add_argument("--to-lane", required=True); send.add_argument("--agent", required=True); send.add_argument("--kind", choices=("finding", "blocked", "evidence-ready", "status"), required=True); send.add_argument("--message", required=True); send.add_argument("--reference", default=""); send.add_argument("--requires-ack", action="store_true"); send.set_defaults(func=cmd_send)
    inbox = sub.add_parser("inbox"); inbox.add_argument("run"); inbox.add_argument("lane"); inbox.set_defaults(func=cmd_inbox)
    ack_message = sub.add_parser("ack-message"); ack_message.add_argument("run"); ack_message.add_argument("lane"); ack_message.add_argument("message_id"); ack_message.add_argument("--agent", required=True); ack_message.set_defaults(func=cmd_ack_message)
    beat = sub.add_parser("heartbeat"); beat.add_argument("run"); beat.add_argument("lane"); beat.add_argument("--agent", required=True); beat.add_argument("--progress", help="what the lane is doing right now"); beat.set_defaults(func=cmd_heartbeat)
    reap = sub.add_parser("reap"); reap.add_argument("run"); reap.add_argument("--lane"); reap.set_defaults(func=cmd_reap)
    watch = sub.add_parser("watch"); watch.add_argument("run"); watch.add_argument("--stale-seconds", type=int, default=900); watch.set_defaults(func=cmd_watch)
    archive = sub.add_parser("archive"); archive.add_argument("run"); archive.set_defaults(func=cmd_archive)
    return root


if __name__ == "__main__":
    args = parser().parse_args()
    args.func(args)

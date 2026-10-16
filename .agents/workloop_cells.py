"""Read-only cells in a run: research, review and QA cells that return text.

A cell is a light entry beside the lanes (ruling 8): no worktree, branch,
install or claim. `add-cell` records it `out`; `returned` records where its
result went, or that it failed; `brief --again` sends a returned or failed
cell out again, tracked until it returns. `check`, `teardown` and the session
end wait for every cell out (`cell_problems`); `integrate` does not, since a
QA cell recorded before the merge waits for that merge. A run declared
without `--verify` holds cells only and is finished once it holds a cell and
every cell is back (ruling 35).
"""

from __future__ import annotations

import argparse
from pathlib import Path

# A module import, never a from-import: workloop_main imports this module for
# cell_problems and workloop_lanes for status_lines, and workloop_lanes imports
# workloop_main, so whichever of the three is imported first finds the others
# half-initialised and a from-import would fail.
import workloop_lanes as wl
from workloop_paths import BRIEF_FOLDER, WORKTREES
from workloop_state import ReadStore, Store, fail, now, record, replayed, run_of, state_path, valid_name

ROLES = {
    "research": "find and ground the facts the objective needs, each with its source and date",
    "review": "review the artefact the objective names against the repository's rules and the run's acceptance; each finding carries a severity and its evidence",
    "qa": "run each scenario the acceptance names, as the working practice below says, and report evidence, failures and coverage gaps",
}
READ_ONLY = "READ-ONLY — this cell reads the checkout and writes nothing; its result is its reply."


def cells_of(run: dict) -> dict:
    """A run's cells; a run from before cells were recorded holds none."""
    return run.get("cells") or {}


def cell_of(run: dict, name: str) -> dict:
    cell = cells_of(run).get(name)
    if cell is None:
        fail(f"run has no cell named {name!r}")
    return cell


def cell_problems(run: dict) -> list[str]:
    """One `cell:<name>:out` per cell not yet back; a failed cell is recorded, not blocking."""
    return [f"cell:{name}:out" for name, cell in sorted(cells_of(run).items()) if cell["state"] == "out"]


def status_lines(run: dict) -> list[str]:
    lines = []
    for name, cell in sorted(cells_of(run).items()):
        where = f"\tresult={cell['result']}" if cell.get("result") else f"\treason={cell['reason']}" if cell.get("reason") else ""
        lines.append(f"{name}\tcell {cell['state']}\t{cell['role']}\tmodel={cell['model']}{where}")
    return lines


def cmd_add_cell(args: argparse.Namespace) -> None:
    valid_name("cell", args.name)
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if replayed(run, args.event_id): print("replayed event"); return
        # One namespace per run: `brief <run> <name>` must name one thing.
        if args.name in run["lanes"] or args.name in cells_of(run):
            fail(f"run already has a lane or cell named {args.name!r}")
        cell = run.setdefault("cells", {})[args.name] = {"role": args.role, "model": args.model, "state": "out", "added_at": now(), "out_since": now()}
        record(args.run, run, "add-cell", args.name, f"{args.role} {args.model}", args.event_id)
    print(cell_prompt(state_path(args.state), args.run, run, args.name, cell))


def cmd_returned(args: argparse.Namespace) -> None:
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if replayed(run, args.event_id): print("replayed event"); return
        cell = cell_of(run, args.name)
        if cell["state"] != "out":
            fail(f"cell {args.name!r} is {cell['state']}, not out; brief {args.run} {args.name} --again sends it out again")
        if args.failed:
            cell["state"], cell["reason"] = "failed", args.failed
            cell.pop("result", None)
        else:
            if args.result != "reply":
                target = Path(args.result) if Path(args.result).is_absolute() else Path(run["repo"]) / args.result
                if not target.is_file():
                    fail(f"--result {args.result} names no file; it names a file the lead wrote, or the word reply")
            cell["state"], cell["result"] = "returned", args.result
            cell.pop("reason", None)
        cell["returned_at"] = now()
        record(args.run, run, "returned", args.name, f"failed: {args.failed}" if args.failed else args.result, args.event_id)
    print(f"cell {args.name!r} {cell['state']}" + (f"; still out: {', '.join(sorted(n for n, c in cells_of(run).items() if c['state'] == 'out'))}" if cell_problems(run) else ""))


def cmd_brief(args: argparse.Namespace) -> None:
    """A lane's role brief, or a cell's prompt; `--again` sends a returned or failed cell out again."""
    with ReadStore(state_path(args.state)) as data:
        run = run_of(data, args.run)
        is_cell = args.lane in cells_of(run)
    if not is_cell:
        if args.again:
            fail(f"--again sends a returned or failed cell out again; {args.lane!r} is a lane, whose brief prints without it")
        lane = wl.lane_of(run, args.lane)
        print(wl.dispatch_prompt(state_path(args.state), args.run, run, args.lane, lane, args.role or "worker"))
        return
    if args.role:
        fail(f"a cell's role is set at add-cell; brief {args.run} {args.lane} takes no --role for cell {args.lane!r}")
    if not args.again:
        cell = cell_of(run, args.lane)
        if cell["state"] != "out":
            fail(f"cell {args.lane!r} is {cell['state']}; a cell dispatched again is tracked again: brief {args.run} {args.lane} --again")
        print(cell_prompt(state_path(args.state), args.run, run, args.lane, cell))
        return
    with Store(state_path(args.state)) as data:
        run = run_of(data, args.run)
        if replayed(run, args.event_id): print("replayed event"); return
        cell = cell_of(run, args.lane)
        if cell["state"] == "out":
            fail(f"cell {args.lane!r} is out already; brief without --again reprints its prompt")
        cell["state"], cell["out_since"] = "out", now()
        for key in ("result", "reason", "returned_at"):
            cell.pop(key, None)
        record(args.run, run, "brief-again", args.lane, cell["role"], args.event_id)
    print(cell_prompt(state_path(args.state), args.run, run, args.lane, cell))


def cell_prompt(state: Path, run_name: str, run: dict, name: str, cell: dict) -> str:
    """Write the cell's brief under the run's folder and return the short prompt the lead pastes."""
    command = f".agents/workloop.py --state {state}"
    # `cell-` keeps it apart from a main lane's `<lane>-reviewer.md` and `<lane>-qa.md` beside it.
    brief_file = Path(run["repo"]) / WORKTREES / run_name / BRIEF_FOLDER / f"cell-{name}.md"
    brief_file.parent.mkdir(parents=True, exist_ok=True)
    (brief_file.parent / ".gitignore").write_text("*\n")
    header = f"WORKLOOP CELL BRIEF — {run_name}/{name}"
    brief_file.write_text("\n".join((
        READ_ONLY,
        header,
        f"Objective: {run['objective']}",
        f"Acceptance: {run['acceptance']}",
        f"Role: {cell['role']} — {ROLES[cell['role']]}.",
        f"Model: {cell['model']}",
        f"Workspace: the checkout {run['repo']}, read only — no worktree, no branch, no claim; another cell may be writing in it, so read committed state where it matters.",
        f"Return: your whole result is your reply to the lead — findings, evidence, open questions — and you write no file. The lead records where it went with: {command} returned {run_name} {name} --result <path|reply>, or --failed '<why>' when you could not finish.",
        *([wl.WORKING_PRACTICE.read_text().strip()] if cell["role"] == "qa" else []),
        f"State: {command} status {run_name}",
    )) + "\n")
    # The gate reads the first line: READ-ONLY holds the cell to reading.
    return "\n".join((READ_ONLY, header, f"Read the full brief at {brief_file} before anything else; it holds your question, what you return and to whom."))

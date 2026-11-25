#!/usr/bin/env python3
"""Gate `workloop.py save-reply`: a cell's final report is saved word for word.

A research fan-out's findings exist only in each agent's transcript, which
Claude Code keeps under a config folder's `projects/<project>/<session>/
subagents/`. The command copies the report out byte for byte, so the lead never
retypes it. These cases build fake transcripts under a scratch HOME and run the
real controller against a scratch checkout. They fail if the saved file differs
from the message by one byte, if a second hand-back does not replace the first,
or if a cell without a report, without an agent id, or in a closed run writes
anything.
"""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOL = [sys.executable, str(REPO / ".agents/workloop.py")]
FIRST = "Résumé — α\n  indented line\nlast line, no blank after"
SECOND = "second report\n"
ANSWER = "final plain answer, no hand-back"
failures: list[str] = []


def check(condition: bool, what: str) -> None:
    if not condition:
        failures.append(what)
        print(f"FAIL: {what}", file=sys.stderr)
    else:
        print(f"ok: {what}")


def record(kind: str, blocks: list[dict], stop: str | None = None) -> str:
    message: dict = {"content": blocks}
    if stop:
        message["stop_reason"] = stop
    # Claude Code writes compact JSON; the reader finds a call by its bytes.
    return json.dumps({"type": kind, "timestamp": "2026-11-25T10:00:00.000Z", "cwd": "/scratch", "message": message},
                      ensure_ascii=False, separators=(",", ":"))


def handback(text: str) -> str:
    block = {"type": "tool_use", "id": "t-" + str(len(text)), "name": "SubagentHandback", "input": {"message": text}}
    return record("assistant", [block], "tool_use")


def write_agent(folder: Path, agent_id: str, lines: list[str], finish: bool = True) -> None:
    path = folder / f"agent-{agent_id}.jsonl"
    path.write_text("\n".join(lines) + ("\n" if finish else ""), encoding="utf-8")


def run(env: dict, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([*TOOL, *args], capture_output=True, text=True, env=env)


def git(*args: str, cwd: Path) -> None:
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True,
                   env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"})


with tempfile.TemporaryDirectory() as scratch_name:
    scratch = Path(scratch_name).resolve()
    work, home, state = scratch / "work", scratch / "home", scratch / "state.json"
    work.mkdir()
    git("init", "-q", "-b", "main", cwd=work)
    (work / "readme.txt").write_text("x\n")
    git("add", "readme.txt", cwd=work)
    git("commit", "-q", "-m", "init", cwd=work)
    store = home / ".claude" / "projects" / "-p" / "sess" / "subagents"
    store.mkdir(parents=True)
    ask = record("user", [{"type": "text", "text": "question"}])
    write_agent(store, "a1", [ask, handback(FIRST)])
    write_agent(store, "a2", [ask, handback("first report"), handback(SECOND)])
    write_agent(store, "a3", [ask, record("assistant", [{"type": "text", "text": ANSWER}], "end_turn")])
    write_agent(store, "a4", [ask, record("assistant", [{"type": "tool_use", "id": "x", "name": "Bash", "input": {}}], "tool_use")])
    # A hand-back call the agent is still writing: the last line has no newline and is cut off.
    write_agent(store, "a6", [ask, handback("cut")[:-9]], finish=False)
    env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CONFIG_DIR"}
    env["HOME"] = str(home)
    base = ["--state", str(state)]

    created = run(env, *base, "init", "rr", "--objective", "o", "--acceptance", "a", "--repo", str(work))
    check(created.returncode == 0, f"init makes a fan-out run: {created.stderr.strip()}")
    for name in ("c1", "c2", "c3", "c4", "c5", "c6", "c7"):
        run(env, *base, "add-cell", "rr", name, "--role", "research", "--model", "sonnet")
    data = json.loads(state.read_text())
    cells = data["runs"]["rr"]["cells"]
    for name, agent in (("c1", "a1"), ("c2", "a2"), ("c3", "a3"), ("c4", "a4"), ("c6", "a6"), ("c7", "gone")):
        cells[name]["agent_id"] = agent
    state.write_text(json.dumps(data))
    replies = work / ".agents/worktrees/rr/.workloop/replies"

    one = run(env, *base, "save-reply", "rr", "c1")
    saved = (replies / "c1.txt").read_bytes() if (replies / "c1.txt").exists() else b""
    check(one.returncode == 0 and saved == FIRST.encode("utf-8"), f"one hand-back is saved byte for byte: {one.stderr.strip() or one.stdout.strip()}")
    digest = hashlib.sha256(FIRST.encode("utf-8")).hexdigest()
    check(f"saved {len(FIRST)} characters" in one.stdout and digest in one.stdout and "1 hand-back" in one.stdout,
          f"the output names the character count, the sha256 and one hand-back: {one.stdout.strip()}")

    two = run(env, *base, "save-reply", "rr", "c2")
    check(two.returncode == 0 and (replies / "c2.txt").read_bytes() == SECOND.encode("utf-8") and "2 hand-backs; saved the last" in two.stdout,
          f"two hand-backs save the second and say so: {two.stdout.strip()}")

    plain = run(env, *base, "save-reply", "rr", "c3")
    check(plain.returncode == 0 and (replies / "c3.txt").read_bytes() == ANSWER.encode("utf-8") and "no hand-back; saved the final answer" in plain.stdout,
          f"no hand-back saves the final answer and says so: {plain.stdout.strip()}")

    unfinished = run(env, *base, "save-reply", "rr", "c4")
    check(unfinished.returncode != 0 and "has not finished" in unfinished.stderr and not (replies / "c4.txt").exists(),
          f"an agent that has not finished writes nothing: {unfinished.stderr.strip()}")
    cut = run(env, *base, "save-reply", "rr", "c6")
    check(cut.returncode != 0 and not (replies / "c6.txt").exists(),
          f"a hand-back still being written is not saved: {cut.stderr.strip()}")
    noid = run(env, *base, "save-reply", "rr", "c5")
    check(noid.returncode != 0 and "no agent id" in noid.stderr and not (replies / "c5.txt").exists(),
          f"a cell with no agent id is named and writes nothing: {noid.stderr.strip()}")
    missing = run(env, *base, "save-reply", "rr", "c7")
    check(missing.returncode != 0 and str(home / ".claude" / "projects") in missing.stderr and not (replies / "c7.txt").exists(),
          f"an agent with no transcript names the folders searched: {missing.stderr.strip()}")

    again = run(env, *base, "save-reply", "rr", "c1")
    check(again.returncode == 0 and "unchanged" in again.stdout, f"the same content again is unchanged: {again.stdout.strip()}")
    replies.mkdir(parents=True, exist_ok=True)
    (replies / "c1.txt").write_text("edited by hand")
    refused = run(env, *base, "save-reply", "rr", "c1")
    check(refused.returncode != 0 and (replies / "c1.txt").read_text() == "edited by hand" and "--force" in refused.stderr,
          f"a changed file is not overwritten without --force: {refused.stderr.strip()}")
    forced = run(env, *base, "save-reply", "rr", "c1", "--force")
    check(forced.returncode == 0 and (replies / "c1.txt").read_bytes() == FIRST.encode("utf-8"), "--force restores the report")

    target = scratch / "elsewhere" / "report.txt"
    placed = run(env, *base, "save-reply", "rr", "c2", "--to", str(target))
    check(placed.returncode == 0 and target.read_bytes() == SECOND.encode("utf-8"), f"--to names the file: {placed.stderr.strip()}")

    closed = run(env, *base, "abandon", "rr")
    check(closed.returncode == 0, f"abandon closes the run: {closed.stderr.strip()}")
    shut = run(env, *base, "save-reply", "rr", "c1")
    check(shut.returncode != 0 and "--to" in shut.stderr, f"a closed run needs --to: {shut.stderr.strip()}")
    kept = scratch / "kept.txt"
    after = run(env, *base, "save-reply", "rr", "c1", "--to", str(kept))
    check(after.returncode == 0 and kept.read_bytes() == FIRST.encode("utf-8"), f"a closed run saves to --to: {after.stderr.strip()}")

if failures:
    print(f"{len(failures)} failed", file=sys.stderr)
    sys.exit(1)
print("all save-reply cases passed")

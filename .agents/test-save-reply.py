#!/usr/bin/env python3
"""Gate `workloop.py save-reply`: a cell's final report is saved word for word.

A research fan-out's findings exist only in each agent's transcript, which
Claude Code keeps under a config folder's `projects/<project>/<session>/
subagents/`. The command copies the report out byte for byte, so the lead never
retypes it. These cases build fake transcripts under a scratch HOME and run the
real controller against a scratch checkout. They fail if the saved file differs
from the message by one byte, if a second hand-back does not replace the first,
if the text of a turn the agent ended to wait on its own command is saved as a
final report, or if a cell without a report, without an agent id, or in a closed
run writes anything.
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
AGENT = {"c1": "a1", "c2": "a2", "c3": "a3", "c4": "a4", "c6": "a6", "c7": "gone", "c8": "a8",
         "c9": "a9", "c10": "a10", "c11": "a11", "c12": "a12", "c13": "a13"}
failures: list[str] = []


def check(condition: bool, what: str) -> None:
    if not condition:
        failures.append(what)
        print(f"FAIL: {what}", file=sys.stderr)
    else:
        print(f"ok: {what}")


def record(kind: str, blocks: list[dict], stop: str | None = None, mid: str | None = None) -> str:
    message: dict = {"content": blocks}
    if stop:
        message["stop_reason"] = stop
    if mid:
        message["id"] = mid
    # Claude Code writes compact JSON; the reader finds a call by its bytes.
    return json.dumps({"type": kind, "timestamp": "2026-11-25T10:00:00.000Z", "cwd": "/scratch", "message": message},
                      ensure_ascii=False, separators=(",", ":"))


def handback(text: str) -> str:
    block = {"type": "tool_use", "id": "t-" + str(len(text)), "name": "SubagentHandback", "input": {"message": text}}
    return record("assistant", [block], "tool_use")


def text_block(text: str) -> dict:
    return {"type": "text", "text": text}


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
    ask = record("user", [text_block("question")])
    tool_result = record("user", [{"type": "tool_result", "tool_use_id": "b1", "content": "started"}])
    write_agent(store, "a1", [ask, handback(FIRST)])
    write_agent(store, "a2", [ask, handback("first report"), handback(SECOND)])
    write_agent(store, "a3", [ask, record("assistant", [text_block(ANSWER)], "end_turn")])
    write_agent(store, "a4", [ask, record("assistant", [{"type": "tool_use", "id": "x", "name": "Bash", "input": {}}], "tool_use")])
    # A hand-back call the agent is still writing: the last line has no newline and is cut off.
    write_agent(store, "a6", [ask, handback("cut")[:-9]], finish=False)
    # A hand-back whose message is not text: Claude Code never writes one, so the format has changed.
    numeric = {"type": "tool_use", "id": "n", "name": "SubagentHandback", "input": {"message": 5}}
    write_agent(store, "a8", [ask, handback("good"), record("assistant", [numeric], "tool_use")])
    # The agent started a command in the background and ended its turn to wait on it: that text is no report.
    background = {"type": "tool_use", "id": "b1", "name": "Bash", "input": {"command": "make", "run_in_background": True}}
    write_agent(store, "a9", [ask, record("assistant", [background], "tool_use"), tool_result,
                              record("assistant", [text_block("waiting for the build")], "end_turn")])
    # Claude Code writes one record per content block of a message, all with the message's id; the final
    # answer is every text block of the newest message and nothing from an earlier one.
    call = {"type": "tool_use", "id": "x", "name": "Bash", "input": {"command": "ls"}}
    write_agent(store, "a10", [ask, record("assistant", [text_block("before the tool")], mid="m0"),
                               record("assistant", [call], "tool_use", mid="m0"), tool_result,
                               record("assistant", [{"type": "thinking", "thinking": "hm"}], mid="m1"),
                               record("assistant", [text_block("part one")], mid="m1"),
                               record("assistant", [text_block("part two")], "end_turn", mid="m1")])
    # A rejected hand-back with no message, then the real one; and a transcript whose only calls are empty.
    write_agent(store, "a11", [ask, handback("real report"), handback("")])
    write_agent(store, "a12", [ask, handback("")])
    write_agent(store, "a13", [ask, '{"type":"assistant","message":{"name":"SubagentHandback" broken'])
    # A second config folder: a missing transcript names every folder searched.
    (home / ".claude-second" / "projects").mkdir(parents=True)
    env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CONFIG_DIR"}
    env["HOME"] = str(home)
    base = ["--state", str(state)]

    created = run(env, *base, "init", "rr", "--objective", "o", "--acceptance", "a", "--repo", str(work))
    check(created.returncode == 0, f"init makes a fan-out run: {created.stderr.strip()}")
    for name in ("c1", "c2", "c3", "c4", "c5", "c6", "c7", "c8", "c9", "c10", "c11", "c12", "c13"):
        run(env, *base, "add-cell", "rr", name, "--role", "research", "--model", "sonnet")
    data = json.loads(state.read_text())
    cells = data["runs"]["rr"]["cells"]
    for name, agent in AGENT.items():
        cells[name]["agent_id"] = agent
    state.write_text(json.dumps(data))
    replies = work / ".agents/worktrees/rr/.workloop/replies"

    def reply(cell: str) -> Path:
        return replies / f"{cell}-{AGENT.get(cell, 'none')}.txt"

    one = run(env, *base, "save-reply", "rr", "c1")
    saved = reply("c1").read_bytes() if reply("c1").exists() else b""
    check(one.returncode == 0 and saved == FIRST.encode("utf-8"), f"one hand-back is saved byte for byte: {one.stderr.strip() or one.stdout.strip()}")
    digest = hashlib.sha256(FIRST.encode("utf-8")).hexdigest()
    check(f"saved {len(FIRST)} characters" in one.stdout and digest in one.stdout and "1 hand-back" in one.stdout,
          f"the output names the character count, the sha256 and one hand-back: {one.stdout.strip()}")

    two = run(env, *base, "save-reply", "rr", "c2")
    check(two.returncode == 0 and reply("c2").read_bytes() == SECOND.encode("utf-8") and "2 hand-backs; saved the last" in two.stdout,
          f"two hand-backs save the second and say so: {two.stdout.strip()}")

    plain = run(env, *base, "save-reply", "rr", "c3")
    check(plain.returncode == 0 and reply("c3").read_bytes() == ANSWER.encode("utf-8") and "no hand-back; saved the final answer" in plain.stdout,
          f"no hand-back saves the final answer and says so: {plain.stdout.strip()}")

    blocks = run(env, *base, "save-reply", "rr", "c10")
    check(blocks.returncode == 0 and reply("c10").read_bytes() == b"part one\npart two",
          f"a final answer split over records of one message is saved whole and without the earlier message: {blocks.stdout.strip() or blocks.stderr.strip()}")

    unfinished = run(env, *base, "save-reply", "rr", "c4")
    check(unfinished.returncode != 0 and "has not finished" in unfinished.stderr and not reply("c4").exists(),
          f"an agent that has not finished writes nothing: {unfinished.stderr.strip()}")
    waiting = run(env, *base, "save-reply", "rr", "c9")
    check(waiting.returncode != 0 and "background" in waiting.stderr and not reply("c9").exists(),
          f"an agent that ended its turn to wait on its own command writes nothing: {waiting.stderr.strip() or waiting.stdout.strip()}")
    cut = run(env, *base, "save-reply", "rr", "c6")
    check(cut.returncode != 0 and not reply("c6").exists(),
          f"a hand-back still being written is not saved: {cut.stderr.strip()}")
    noid = run(env, *base, "save-reply", "rr", "c5")
    check(noid.returncode != 0 and "no agent id" in noid.stderr and not list(replies.glob("c5-*")),
          f"a cell with no agent id is named and writes nothing: {noid.stderr.strip()}")
    missing = run(env, *base, "save-reply", "rr", "c7")
    check(missing.returncode != 0 and not reply("c7").exists()
          and all(str(home / name / "projects") in missing.stderr for name in (".claude", ".claude-second")),
          f"an agent with no transcript names every folder searched: {missing.stderr.strip()}")
    odd = run(env, *base, "save-reply", "rr", "c8")
    check(odd.returncode != 0 and "message that is not text" in odd.stderr and "Traceback" not in odd.stderr and not reply("c8").exists(),
          f"a hand-back whose message is not text is a named error, and writes nothing: {odd.stderr.strip()}")
    rejected = run(env, *base, "save-reply", "rr", "c11")
    check(rejected.returncode == 0 and reply("c11").read_bytes() == b"real report" and "1 hand-back" in rejected.stdout,
          f"an empty hand-back beside a real one is skipped: {rejected.stdout.strip() or rejected.stderr.strip()}")
    blank = run(env, *base, "save-reply", "rr", "c12")
    check(blank.returncode != 0 and "has no message" in blank.stderr and not reply("c12").exists(),
          f"a transcript whose only hand-back is empty writes nothing: {blank.stderr.strip()}")
    broken = run(env, *base, "save-reply", "rr", "c13")
    check(broken.returncode != 0 and "is not JSON" in broken.stderr and "Traceback" not in broken.stderr and not reply("c13").exists(),
          f"a corrupt line that holds a hand-back call is a named error: {broken.stderr.strip()}")

    again = run(env, *base, "save-reply", "rr", "c1")
    check(again.returncode == 0 and "unchanged" in again.stdout, f"the same content again is unchanged: {again.stdout.strip()}")
    (reply("c1")).write_text("edited by hand")
    refused = run(env, *base, "save-reply", "rr", "c1")
    check(refused.returncode != 0 and reply("c1").read_text() == "edited by hand" and "--force" in refused.stderr,
          f"a changed file is not overwritten without --force: {refused.stderr.strip()}")
    forced = run(env, *base, "save-reply", "rr", "c1", "--force")
    check(forced.returncode == 0 and reply("c1").read_bytes() == FIRST.encode("utf-8"), "--force restores the report")
    check(not [path for path in replies.iterdir() if path.name.startswith(".")], "no temporary file is left in the replies folder")

    # The cell is dispatched again and a second agent reports: the first report stays.
    data = json.loads(state.read_text())
    data["runs"]["rr"]["cells"]["c1"]["agent_id"] = "a2"
    state.write_text(json.dumps(data))
    second_round = run(env, *base, "save-reply", "rr", "c1")
    check(second_round.returncode == 0 and (replies / "c1-a2.txt").read_bytes() == SECOND.encode("utf-8")
          and (replies / "c1-a1.txt").read_bytes() == FIRST.encode("utf-8"),
          f"a second agent's report for the same cell does not replace the first: {second_round.stderr.strip()}")

    target = scratch / "elsewhere" / "report.txt"
    placed = run(env, *base, "save-reply", "rr", "c2", "--to", str(target))
    check(placed.returncode == 0 and target.read_bytes() == SECOND.encode("utf-8"), f"--to names the file: {placed.stderr.strip()}")

    data = json.loads(state.read_text())
    data["runs"]["rr"]["repo"] = str(scratch / "deleted-checkout")
    state.write_text(json.dumps(data))
    lost = run(env, *base, "save-reply", "rr", "c3")
    check(lost.returncode != 0 and "does not exist" in lost.stderr and not (scratch / "deleted-checkout").exists(),
          f"a run whose checkout is gone does not recreate it: {lost.stderr.strip()}")
    data["runs"]["rr"]["repo"] = str(work)
    state.write_text(json.dumps(data))

    closed = run(env, *base, "abandon", "rr")
    check(closed.returncode == 0, f"abandon closes the run: {closed.stderr.strip()}")
    shut = run(env, *base, "save-reply", "rr", "c1")
    check(shut.returncode != 0 and "--to" in shut.stderr, f"a closed run needs --to: {shut.stderr.strip()}")
    kept = scratch / "kept.txt"
    after = run(env, *base, "save-reply", "rr", "c1", "--to", str(kept))
    check(after.returncode == 0 and kept.read_bytes() == SECOND.encode("utf-8"), f"a closed run saves to --to: {after.stderr.strip()}")

if failures:
    print(f"{len(failures)} failed", file=sys.stderr)
    sys.exit(1)
print("all save-reply cases passed")

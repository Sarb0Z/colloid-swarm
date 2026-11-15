#!/usr/bin/env python3
"""What waits on the operator, shown in iTerm2's Session Status sidebar for this tab.

Usage: iterm_attention.py <repo> <it2>      the normalized hook payload on stdin

hooks/policy/iterm-attention.sh runs this, async, for the main agent on Claude
Code's Stop and Notification `idle_prompt`, and shows the first that applies:

  1. An open gate: `waiting`, detail `decide: <first gate> (+N more)`. A gate
     is a `needs_confirmation:` line of the turn's last message, cut at its
     first " — " (at Stop the payload's message, at idle_prompt the
     transcript's).
  2. A background agent of this session that the death reader
     (agent_deaths.py) shows as dead, first seen by this hook in this turn:
     `error`, detail `agent died: <description> (+N more)`. The reader names
     every death of the session it reads for. The turn starts at the
     transcript's last user prompt; `.agents/.readout/.iterm-deaths-<session>`
     keeps the turn in which each death was first seen, so a death shows at
     this turn's Stop and idle_prompt and never again, and one found at
     `--resume` shows at the end of the resumed session's first turn.
  3. What the session owes (owed.py): detail `owed: <items>`, the status left
     as `done`.
  4. Otherwise nothing is written, and the tab is not read.

A question the question tool asks needs no write: Claude Code (`waiting |
answer: <question> (<options>)`) and iTerm2 (`waiting | <question>`) show it.

None of it runs unless the session is the tab's own interactive Claude:
`ITERM_SESSION_ID` names a tab, and that tab's `claude-tab-state` record
(`$CLAUDE_TAB_STATE_DIR`, default ~/.local/state/iterm-tabs) names this
payload's session, so a headless run, a subagent and another tab's session
write nothing. `hooks.iterm_attention.enabled`, default on, turns it off.

Other writers set a Claude tab's status too, in no fixed order, and which of
them a session has varies: iTerm2's hook (`it2 handle-agent-hook`) writes `done
| <message>` at Stop and `done` again at idle_prompt, over a status of this
hook's; in some sessions Claude Code itself (OSC 21337) clears that detail
about 0.5 s after Stop. Hooks of one event run in parallel, and iTerm2 3.7.7
keeps no turn flag, so `--if-turn-open` alone cannot order the writes. So the
hook waits for none of them: it watches the tab, reading `it2 session
get-status` about every 0.2 s for 6 s at most, and keeps its status the last
write.

  - Until a read shows a turn end, it reads on through `working` and a
    `waiting` that is not this hook's: the turn's own end has not landed. A
    turn end is `done`, `background`, or a status of this hook's, which its
    detail's `decide: `, `agent died: ` or `owed: ` tells.
  - On a turn end that is not the status to show, it writes that status, with
    `--if-turn-open false` when the read shows a turn flag, and writes it
    again each time a later read shows another writer covered it.
  - After a turn end, anything else (`working`, a `waiting` that is not this
    hook's, `idle`) is a new turn or a prompt, and the watch stops at once.

A Stop whose turn a synchronous hook continues shows the status until the next
`working`, which removes a status of any turn. The hook keeps no status of its
own between runs.

A failure is reported on stderr and in one line of
`.agents/.readout/.iterm-attention.log`, and the hook goes on or stops quietly;
the policy always exits 0.
"""

from __future__ import annotations

import collections
import functools
import importlib.util
import json
import os
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

STOP, IDLE = "Stop", "idle_prompt"
UUID = r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
# claude-tab-state's names: a tab is `w<n>t<n>p<n>:<GUID>` in ITERM_SESSION_ID, its
# record <state>/<GUID>.claude.json with the GUID upper-cased, and `it2 --session`
# takes the same GUID.
TAB_ID = re.compile(rf"w\d+t\d+p\d+:({UUID})")
LOG = Path(".readout") / ".iterm-attention.log"
DETAIL_MAX = 180  # where iTerm2 cuts its own details (AgentHookDetail.condense)
READ_EVERY = 0.2  # from one read's start to the next; a get-status itself took 0.2 s on 3.7.7
WATCH_FOR = 6.0
IT2_TIMEOUT = 2.0  # one it2 call
# What this hook's details start with: how a read tells its own status from another writer's.
OURS = ("decide: ", "agent died: ", "owed: ")
TURN_END = ("done", "background")
# iTerm2's own palette (AgentHookPalette), so a status written here reads as one it wrote.
COLORS = {"waiting": "#5f87ff", "error": "#ff3b30"}
GATE = re.compile(r"^[ \t]*(?:[-*][ \t]+)?`?needs_confirmation:(.*)$", re.M)
# The first-seen record of this session's deaths, a ledger of this unit's own in
# `.readout/`: no `.json` suffix, since readout.py reads every `*.json` there as a readout.
SEEN = ".iterm-deaths-{}"

# A status to write: `status` None keeps the tab's `done` and writes the detail alone.
Plan = collections.namedtuple("Plan", "status text")


def event_of(payload: dict) -> str | None:
    event = payload.get("event")
    if event == "Stop":
        return STOP
    if event == "Notification" and payload.get("notification_type") == "idle_prompt":
        return IDLE
    return None


def tab_of(environ) -> str | None:
    match = TAB_ID.fullmatch(environ.get("ITERM_SESSION_ID", ""))
    return match.group(1).upper() if match else None


def tab_session(state: Path, tab: str) -> str | None:
    """The session the tab's record names; None when the tab has no record."""
    path = state / f"{tab}.claude.json"
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    if not isinstance(record, dict) or not isinstance(record.get("session_id"), str):
        raise ValueError(f"the tab record {path} names no session_id")
    return record["session_id"]


def condense(text: str, limit: int = DETAIL_MAX) -> str:
    """Whitespace runs as one space, cut to `limit` characters with an ellipsis, as iTerm2 cuts."""
    text = " ".join(text.split())
    return text if len(text) <= limit else text[:limit - 1] + "…"


def counted(head: str, first: str, others: int) -> str:
    """`<head><first>`, then ` (+N more)`; a detail past the limit loses its text, never the count."""
    more = f" (+{others} more)" if others else ""
    return condense(head + first, DETAIL_MAX - len(more)) + more


def gates_in(message: str) -> list[str]:
    """Each `needs_confirmation:` line's gate: its text up to the first " — "."""
    found = []
    for match in GATE.finditer(message):
        # "`needs_confirmation:` lines are ..." is prose about the marker, not a gate.
        if match.group(1).startswith("`"):
            continue
        gate = match.group(1).split(" — ", 1)[0].strip().strip("`").strip()
        if gate:
            found.append(gate)
    return found


def _module(name: str):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), HERE / f"{name}.py")
    if spec is None or spec.loader is None:
        raise ImportError(f"{HERE / f'{name}.py'} cannot be loaded as a module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def last_turn(transcript: str) -> tuple[str, str]:
    """(the turn's start, the text of its last assistant row) for the transcript's last turn. The
    start is the uuid of the user prompt that began it, as `turn-text.py --turn-id` names it,
    "start" before any prompt; the text is "" when the turn has none yet. The file is read from
    its end, so the cost is the turn's size, not the session's."""
    turn_text = _module("turn-text")
    last = ""
    for raw in turn_text.lines_reversed(transcript):
        try:
            row = json.loads(raw)
        except ValueError:
            continue  # a blank line, or the last one while Claude Code still writes it
        if not isinstance(row, dict) or row.get("isSidechain") or row.get("isMeta"):
            continue
        # An `api-request-blob` row carries a message with a role too, and no uuid or timestamp.
        if row.get("type") not in ("user", "assistant"):
            continue
        message = row.get("message")
        if not isinstance(message, dict):
            continue
        if message.get("role") == "user" and turn_text.typed_by_user(message):
            return str(row.get("uuid") or row.get("timestamp") or "start"), last
        if message.get("role") == "assistant" and not last:
            last = turn_text.text_of(message) or ""
    return "start", last


def session_deaths(dead: list[str], agents: Path) -> list[tuple[str, str]]:
    """(agent id, description) of each agent among the dead agents `dead`, newest first, that is
    a background agent of the session whose agent transcripts are in `agents`."""
    import agent_records
    found = []
    for agent_id in dead:
        transcript = agents / f"agent-{agent_id}.jsonl"
        if transcript.is_file() and (meta := agent_records.read_meta(transcript))["background"]:
            found.append((agent_id, meta["description"]))
    return found


def read_deaths(repo: Path, session: str, transcript: str) -> list[tuple[str, str]]:
    """`session_deaths` over the death reader's report, which reads Claude Code's records as the
    lead's prompt hook does and leaves its cache warm for that hook. The reader names every
    dead agent of the session it reads for (agent_leftovers.leftovers)."""
    if not transcript:
        raise ValueError("the payload names no transcript, so this session's agents cannot be told")
    import agent_deaths
    import agent_effects
    from workloop_size import GitBudget
    runs = agent_effects.runs_at(repo / agent_effects.STATE)
    report = agent_deaths.report(repo, session, runs, agent_effects.real(GitBudget().out))
    return session_deaths(list(report.dead), Path(transcript).with_suffix("") / "subagents")


def first_seen(seen: dict, deaths: list[tuple[str, str]], turn: str) -> dict:
    """The record to keep: each agent the reader still reports dead, with the turn in which this
    hook first saw it; an agent the reader no longer reports is dropped."""
    return {agent_id: seen.get(agent_id, turn) for agent_id, _ in deaths}


def found_this_turn(seen: dict, deaths: list[tuple[str, str]], turn: str) -> list[str]:
    """The descriptions of the deaths first seen in this turn, newest first."""
    return [description for agent_id, description in deaths if seen.get(agent_id) == turn]


def read_seen(path: Path) -> dict:
    """The first-seen record, {} when there is none. One that does not read as an object of
    agent ids to turn starts raises ValueError."""
    try:
        seen = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    if not isinstance(seen, dict) or not all(isinstance(turn, str) for turn in seen.values()):
        raise ValueError(f"{path} holds no record of agent ids and turn starts")
    return seen


def write_seen(path: Path, seen: dict) -> None:
    """Replace the record atomically; an empty one removes the file."""
    if not seen:
        path.unlink(missing_ok=True)
        return
    import agent_effects
    path.parent.mkdir(parents=True, exist_ok=True)
    agent_effects.write_atomic(path, json.dumps(seen, separators=(",", ":")))


def read_owed(repo: Path, session: str) -> str:
    """owed.py's strip for the session, `owed: <items>`, or "" when nothing is owed."""
    import owed
    return owed.compute(str(repo), session, owed.cksum_key(session))[1]


def decide(gates: list[str], dead, owed) -> Plan | None:
    """What to write, or None. `dead` (the descriptions of the deaths first seen this turn) and
    `owed` are called only when no earlier row decides, since each reads Claude Code's records
    or Git."""
    if gates:
        return Plan("waiting", counted("decide: ", gates[0], len(gates) - 1))
    if named := dead():
        return Plan("error", counted("agent died: ", named[0], len(named) - 1))
    if strip := owed():
        return Plan(None, condense(strip))
    return None


def status_of(text: str) -> dict:
    data = json.loads(text)
    if not isinstance(data, dict) or not all(isinstance(data.get(key) or "", str) for key in ("status", "detail")):
        raise ValueError(f"it2 session get-status printed {text.strip()[:80]!r}, which is no status")
    return {"status": data.get("status") or "", "detail": data.get("detail") or "", "turn_open": data.get("turn_open")}


def turn_end(current: dict) -> bool:
    """Whether the tab shows a turn that has ended: `done`, `background` for a turn that ends
    with work still running, or a status of this hook's, which only a turn's end writes."""
    return current["status"] in TURN_END or current["detail"].startswith(OURS)


def shows(plan: Plan, current: dict) -> bool:
    """Whether the tab shows the plan as this hook writes it; the owed detail sits on `done`."""
    return current["detail"] == plan.text and current["status"] == (plan.status or "done")


def watch(plan: Plan, read, write, sleep, clock) -> None:
    """Keep the plan the tab's last write for WATCH_FOR seconds at most. `read` gives the tab's
    status and `write` takes set-status's options. Before a read shows a turn end, anything
    else is this turn still running; after one, it is a new turn or a prompt, and the watch
    stops. On each turn end that is not the plan, the plan is written."""
    deadline = clock() + WATCH_FOR
    ended = False
    while True:
        started = clock()
        current = read()
        if turn_end(current):
            ended = True
            if not shows(plan, current) and (args := write_args(plan, current)):
                write(args)
        elif ended:
            return
        if started + READ_EVERY > deadline:
            return
        sleep(max(0.0, started + READ_EVERY - clock()))


def write_args(plan: Plan, current: dict) -> list[str] | None:
    """set-status's options; None for the owed detail on a tab that shows `background`."""
    if plan.status is None:
        if current["status"] != "done":
            return None
        args = ["--detail", plan.text]
    else:
        color = COLORS[plan.status]
        args = ["--status", plan.status, "--dot-color", color, "--text-color", color, "--detail", plan.text]
    if current["turn_open"] is not None:
        args += ["--if-turn-open", "false"]
    return args


def it2_runner(it2: str, tab: str):
    import subprocess

    def run(verb: str, *args: str) -> str:
        try:
            result = subprocess.run([it2, "session", verb, "--session", tab, *args],
                                    capture_output=True, text=True, timeout=IT2_TIMEOUT)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(f"it2 session {verb} gave no answer within {IT2_TIMEOUT:g} s") from error
        if result.returncode:
            said = (result.stderr or result.stdout).strip()[:200]
            raise RuntimeError(f"it2 session {verb} exited {result.returncode}: {said}")
        return result.stdout
    return run


class Log:
    def __init__(self, repo: Path) -> None:
        self.path, self.where = repo / ".agents" / LOG, "?"

    def fail(self, message: str) -> None:
        print(f"iterm-attention: {self.where}: {message}", file=sys.stderr)
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a", encoding="utf-8") as stream:
                stream.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {self.where}: {message}\n")
        except OSError as error:
            print(f"iterm-attention: could not append to {self.path}: {error}", file=sys.stderr)


def attend(repo: Path, it2: str, raw: str, environ, log: Log) -> None:
    payload = json.loads(raw or "{}")
    if not isinstance(payload, dict):
        raise ValueError("the hook payload is no JSON object")
    event, session, tab = event_of(payload), payload.get("session_id") or "", tab_of(environ)
    if not (event and session and tab):
        return
    log.where = f"session {session} {event}"
    state = Path(environ.get("CLAUDE_TAB_STATE_DIR") or Path.home() / ".local/state/iterm-tabs")
    if tab_session(state, tab) != session:
        return
    import config
    settings = str(repo / ".agents" / "config.json")
    if config.unparsed(settings):
        raise ValueError("policy.json or config.json does not parse, so hooks.iterm_attention.enabled is unknown")
    if not config.read(config.load(settings), "hooks.iterm_attention.enabled", True):
        return

    import subprocess
    transcript = payload.get("transcript_path") or ""
    turn = functools.cache(lambda: last_turn(transcript))

    def dead() -> list[str]:
        try:
            deaths = read_deaths(repo, session, transcript)
            path = repo / ".agents" / ".readout" / SEEN.format(re.sub(r"[^A-Za-z0-9_-]", "", session))
            try:
                seen = read_seen(path)
            except ValueError as error:
                log.fail(f"{error}; it is read as empty, so a death it held may show again")
                seen = {}
            kept = first_seen(seen, deaths, turn()[0])
            if kept != seen:
                write_seen(path, kept)
            return found_this_turn(kept, deaths, turn()[0])
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            log.fail(f"the death reader failed ({error}), so no dead agent is shown")
            return []

    def owed() -> str:
        try:
            return read_owed(repo, session)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            log.fail(f"owed.py failed ({error}), so nothing owed is shown")
            return ""

    message = payload.get("last_assistant_message") if event == STOP else turn()[1]
    plan = decide(gates_in(message or ""), dead, owed)
    if plan is None:
        return
    run = it2_runner(it2, tab)
    watch(plan, lambda: status_of(run("get-status")), lambda args: run("set-status", *args),
          time.sleep, time.monotonic)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.exit("usage: iterm_attention.py <repo> <it2>   (the normalized hook payload on stdin)")
    repo = Path(argv[1])
    log = Log(repo)
    try:
        attend(repo, argv[2], sys.stdin.read(), os.environ, log)
    except (OSError, ValueError, RuntimeError, ImportError) as error:
        log.fail(f"{error}; the tab keeps iTerm2's own status")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

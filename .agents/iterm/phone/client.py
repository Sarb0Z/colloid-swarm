#!/usr/bin/env python3
"""The permission hook's side of the phone link: register with the service, wait, print the phone's decision.

  client.py permission        Claude Code's PermissionRequest payload on stdin

`hooks/phone-permission.sh` runs this for every tool except the question tool
and plan approval, in every session of every account. It always exits 0, and
it prints a decision only when the phone gave one, so in every other case
Claude Code behaves as it does without the link: the dialog stays, or a session
with no dialog denies the call.

  1. Harness. A session whose `cwd` has no `.agents/AGENTS.md` at or above it
     is not the link's: exit at once, silently.
  2. Service. Connect to `<state>/hook.sock`. If phone-link does not answer,
     write one line to stderr and exit.
  3. The call. The payload has no id for its call, so read the last 200 rows
     of the transcript that holds it (the session's, or the agent's own file
     for a payload with `agent_id`) for the calls of this tool and input in
     the latest turn that have not ended, the earliest first: one turn's
     dialogs come in call order. The service binds the event to the
     first that no other waiting hook holds.
  4. Register. One line: the session, the `claude` process and its start, the
     tool, and a preview that is masked and cut before it leaves this process,
     with how many values it masked and characters it cut.
     The raw tool input goes nowhere.
  5. Wait, until the hook's own deadline, 60 s before Claude Code's timeout:
       - a decision from the service: print it and exit;
       - every 2 s, the rows the transcript gained: when they show how this
         call ended, the Mac's dialog answered first, so tell the service and
         exit with no decision;
       - a call not found within 10 s leaves the event unbound, and the wait
         is then 10 minutes at most;
       - the session's `claude` process gone, or the service gone: exit.

The wait takes its effects as parameters (`Effects`), so the tests move the
clock and stand in for the service; `main` wires the real ones.
"""

from __future__ import annotations

import difflib
import json
import os
import select
import socket
import sys
import time
import traceback
from pathlib import Path

import log
import mask
import sessions
import transcript

# The `timeout` install.sh gives the hook in each account's settings, in seconds.
HOOK_TIMEOUT = 3600
OWN_DEADLINE = HOOK_TIMEOUT - 60
POLL_SECONDS = 2
FIND_SECONDS = 10
UNBOUND_SECONDS = 600
START_CHECK_SECONDS = 30
CONNECT_SECONDS = 1
REGISTER_SECONDS = 5
PREVIEW_LINES = 10
DIFFED_LINES = 200
# These two need an answer with `updatedInput`, which this hook never gives.
ANSWERED_AT_THE_MAC = ("AskUserQuestion", "ExitPlanMode")


def harness_root(cwd: str):
    """The nearest folder at or above `cwd` that carries the harness, or None."""
    start = Path(cwd)
    return next((folder for folder in (start, *start.parents) if (folder / ".agents" / "AGENTS.md").exists()), None)


def _changed(old: str, new: str) -> list:
    """The changed lines between two texts, removed ones as `- line`, added ones as `+ line`."""
    diff = list(difflib.unified_diff(old.splitlines()[:DIFFED_LINES], new.splitlines()[:DIFFED_LINES],
                                     lineterm="", n=0))
    # After the two file lines, a line that starts with a sign is a changed line; `@@` opens a hunk.
    return [f"{line[0]} {line[1:]}" for line in diff[2:] if line.startswith(("+", "-"))]


def preview(tool: str, tool_input) -> str:
    """What the alert shows of a call, before masking: a Bash command; for Edit, Write and
    NotebookEdit the path and the first 10 changed lines; any other input as JSON."""
    given = tool_input if isinstance(tool_input, dict) else {}
    if tool == "Bash" and isinstance(given.get("command"), str):
        return given["command"]
    shown = {"Edit": ("file_path", "old_string", "new_string"), "Write": ("file_path", None, "content"),
             "NotebookEdit": ("notebook_path", None, "new_source")}.get(tool)
    if shown and isinstance(given.get(shown[0]), str) and isinstance(given.get(shown[2]), str):
        old = given.get(shown[1]) if shown[1] and isinstance(given.get(shown[1]), str) else ""
        return "\n".join([given[shown[0]], *_changed(old, given[shown[2]])[:PREVIEW_LINES]])
    return json.dumps(tool_input, ensure_ascii=False)


def decision_output(behavior: str, message) -> str:
    decision = {"behavior": behavior}
    if behavior == "deny" and message:
        decision["message"] = message
    return json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}})


class ServiceLink:
    """A connection to phone-link's hook socket: JSON lines both ways."""

    def __init__(self, path: str):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(CONNECT_SECONDS)
        try:
            self.socket.connect(path)
        except OSError:
            self.socket.close()
            raise
        self.buffer = b""

    def send(self, message: dict) -> None:
        self.socket.sendall(json.dumps(message).encode() + b"\n")

    def read(self, seconds: float):
        """The messages that arrive within `seconds`, or None when the service closed the connection."""
        if not select.select([self.socket], [], [], max(0.0, seconds))[0]:
            return []
        data = self.socket.recv(65536)
        if not data:
            return None
        *lines, self.buffer = (self.buffer + data).split(b"\n")
        return [json.loads(line) for line in lines]

    def close(self) -> None:
        self.socket.close()


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class Effects:
    """What the wait reaches outside itself."""

    connect = staticmethod(ServiceLink)
    clock = staticmethod(time.time)
    alive = staticmethod(_alive)
    starts = staticmethod(sessions.process_starts)

    @staticmethod
    def claude():
        """(pid, start) of this hook's Claude Code process, or None."""
        return sessions.claude_process(os.getppid())


def run(payload: dict, environ, effects, out, err) -> int:
    """The hook, from payload to exit code. `out` takes the decision, `err` one line of why not."""
    cwd = payload.get("cwd") or os.getcwd()
    root, tool, transcript_path = harness_root(cwd), payload.get("tool_name"), payload.get("transcript_path")
    if root is None or tool in ANSWERED_AT_THE_MAC:
        return 0
    if not isinstance(tool, str) or not isinstance(transcript_path, str):
        err("the payload names no tool or no transcript; the permission prompt goes on without the phone")
        return 0
    started = effects.clock()
    try:
        link = effects.connect(str(log.state_dir(environ) / "hook.sock"))
    except OSError as error:
        err(f"phone-link does not answer ({error}); the permission prompt goes on without the phone")
        return 0
    try:
        return _wait(payload, environ, effects, out, err, link, started, str(root), cwd)
    except OSError as error:
        err(f"the connection to phone-link failed ({error}); the permission prompt goes on without the phone")
        return 0
    finally:
        link.close()


def _wait(payload, environ, effects, out, err, link, started, root, cwd) -> int:
    tool, tool_input, transcript_path = payload["tool_name"], payload.get("tool_input"), payload["transcript_path"]
    process = effects.claude()
    if process is None:
        err("no claude process is above this hook; the permission prompt goes on without the phone")
        return 0
    pid, start = process
    file = transcript.call_file(transcript_path, payload.get("agent_id"))
    rows, offset = transcript.tail(file)
    calls, follow = transcript.Calls((tool, tool_input)), transcript.Follow(file, offset)
    calls.add(rows)
    offered = calls.waiting()
    config_dir = (transcript_path.split("/projects/")[0] if "/projects/" in transcript_path
                  else environ.get("CLAUDE_CONFIG_DIR") or str(Path(environ["HOME"]) / ".claude"))
    deadline = started + OWN_DEADLINE
    shown = mask.outbound(preview(tool, tool_input))
    link.send({
        "type": "permission",
        "session": {"id": str(payload.get("session_id")), "agent": payload.get("agent_id"), "pid": pid,
                    "start": start, "config_dir": config_dir, "cwd": cwd, "project": os.path.basename(root),
                    "account": environ.get("CLAUDE_PROFILE") or os.path.basename(config_dir).lstrip("."),
                    "transcript": transcript_path},
        "turn": payload.get("prompt_id"), "tool": tool, "preview": shown.text,
        "masked": shown.masked, "cut": shown.cut,
        "calls": offered, "file": file, "deadline": deadline,
    })
    registered, call, unbound_limit_told = False, None, False
    next_poll, next_start_check = started + POLL_SECONDS, started + START_CHECK_SECONDS

    while True:
        messages = link.read(min(next_poll, deadline) - effects.clock())
        if messages is None:
            err("phone-link went away; the permission prompt goes on without the phone")
            return 0
        for message in messages:
            kind = message.get("type")
            if kind == "registered":
                registered, call = True, message.get("call")
            elif kind == "bound":
                call = message.get("call") or call
            elif kind == "decision" and message.get("behavior") in ("allow", "deny"):
                out(decision_output(message["behavior"], message.get("message")))
                return 0
            elif kind == "refused":
                err(f"phone-link refused this prompt ({message.get('reason')}); it goes on without the phone")
                return 0
            elif kind == "failed":
                err(f"phone-link: {message.get('reason')}; the permission prompt goes on without the phone")
                return 0
            elif kind == "dropped":
                return 0
        now = effects.clock()
        if not registered and now - started >= REGISTER_SECONDS:
            err("phone-link did not answer the registration; the permission prompt goes on without the phone")
            return 0
        if now >= next_poll:
            next_poll = now + POLL_SECONDS
            calls.add(follow.read())
            if call is not None:
                ending = calls.ending(call)
                if ending is not None:
                    # The Mac's dialog, or another party, settled this call first.
                    link.send({"type": "settled", "by": ending.by, "decision": ending.decision})
                    return 0
            elif registered:
                if calls.waiting() and calls.waiting() != offered:
                    offered = calls.waiting()
                    link.send({"type": "bind", "calls": offered})
                if not unbound_limit_told and now - started >= FIND_SECONDS:
                    unbound_limit_told, deadline = True, min(deadline, started + UNBOUND_SECONDS)
                    link.send({"type": "deadline", "deadline": deadline})
            gone = not effects.alive(pid)
            if not gone and now >= next_start_check:
                next_start_check = now + START_CHECK_SECONDS
                gone = not sessions.process_start.same_start(start, effects.starts([pid]).get(pid))
            if gone:
                link.send({"type": "gone"})
                return 0
        if now >= deadline:
            link.send({"type": "expired"})
            return 0


def main(argv) -> int:
    def err(text: str) -> None:
        print(f"phone-permission: {text}", file=sys.stderr)

    def out(text: str) -> None:
        sys.stdout.write(text + "\n")
        sys.stdout.flush()

    if argv[1:] != ["permission"]:
        err("usage: client.py permission  (the PermissionRequest payload on stdin)")
        return 0
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            raise ValueError("the payload is not a JSON object")
        return run(payload, os.environ, Effects, out, err)
    except KeyboardInterrupt:
        return 0  # The operator's own Ctrl+C in a session without a dialog: nothing to say.
    except Exception:  # A hook that fails must not block the tool call: say why, and let the dialog decide.
        err("failed, and the permission prompt goes on without the phone:\n" + traceback.format_exc())
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

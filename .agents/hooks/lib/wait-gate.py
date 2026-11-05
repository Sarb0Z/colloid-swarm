#!/usr/bin/env python3
"""Decide whether a shell command waits blind, and say what to do instead.

Input  (stdin JSON): {"command": "<shell command>", "run_in_background": bool,
"timeout": <Bash's timeout parameter in ms, or null>}
Output: exit 2 and the remedy on stderr when a rule fires; exit 0 otherwise.

A foreground `sleep` holds the session and learns nothing; a bare `&` starts a
process the host cannot see, so nothing reports when it ends and the agent
falls back to sleeping and tailing its log. Every agent, lead or spawned cell,
gets the same rules, checked in this order:

* any sleep in a command that reads a host task's output file, which the host
  already reports on completion;
* a sleep whose length cannot be read (`sleep $s`);
* sleeps summed over the top level, or any one inside a loop (condition or body) or an
  `sh -c` payload, longer than SHORT seconds;
* a sleep inside a loop body or an `sh -c` payload when Bash's timeout
  parameter is above its 2-minute default, since the loop can then hold the
  session for that long;
* a segment backgrounded with `&` in a command that never runs `wait`.

A short sleep passes: `kill 123; sleep 2` waits for a port to free, and
`until curl -sf ...; do sleep 2; done` ends the moment the condition holds,
under the default limit. Heredoc bodies are data, as in guard-destructive.
"""

import importlib.util
import json
import math
import os
import re
import shlex
import sys

SHORT = 5.0
TASK_OUTPUT = re.compile(r"/tasks/[A-Za-z0-9_-]+\.output\b")
DURATION = re.compile(r"^(\d+(?:\.\d*)?|\.\d+)([smhd]?)$")
SCALE = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}
WRAPPERS = {"timeout", "gtimeout", "nice", "stdbuf"}
PREFIXES = {"if", "then", "else", "elif", "{", "}", "!", "time", "nohup", "command", "builtin", "exec"}

DEFAULT_TIMEOUT_MS = 120000  # Claude Code's Bash default when no timeout is given
MAX_TIMEOUT_MS = 600000  # the host's ceiling on Bash's timeout parameter

WAIT = """Pick the wait that ends with the event:
- A background shell or agent you started: end your turn. The harness wakes you with its result, a spawned agent included.
- A command you are about to run: up to 10 minutes in the foreground, with Bash's timeout parameter covering it. A longer one, or a server or watcher: its own Bash call with run_in_background: true, stopped with TaskStop when done.
- A condition (a port answers, a file appears) that holds within 2 minutes: its own call under the default limit, with a cap that reports how it ended: for i in $(seq 30); do curl -sf -m 1 http://localhost:3000 >/dev/null && break; sleep 2; done; curl -sf -m 1 http://localhost:3000 >/dev/null && echo up || echo down. A condition that may take longer: that poll with run_in_background: true.
- A short poll before long work (a build, a test run): split it, the poll in one call and the work in the next.
- CI or a deploy: gh run watch <id> --exit-status with run_in_background: true.
A sleep of 5 s or less, written as a number, passes, except inside a loop under a raised time limit."""


def load(name, file):
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location(name, os.path.join(here, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


parser = load("guard_destructive", "guard-destructive.py")


def seconds(words):
    """Total seconds a `sleep` word list asks for, or None when unreadable."""
    total = 0.0
    for word in words[1:]:
        if word == "infinity":
            return float("inf")
        match = DURATION.match(word)
        if not match:
            return None
        total += float(match.group(1)) * SCALE[match.group(2)]
    return total


def unwrap(words):
    """The command a `timeout`, `nice` or `stdbuf` prefix runs."""
    while words and os.path.basename(words[0]) in WRAPPERS:
        takes_value = os.path.basename(words[0]) == "timeout"
        words = words[1:]
        while words and words[0].startswith("-"):
            words = words[1:]
        if takes_value and words:
            words = words[1:]
    return words


def strip_comments(text):
    """Drop each unquoted `#...` comment; `a#b` and a quoted `#` are not one."""
    out, quote, i = [], "", 0
    while i < len(text):
        char = text[i]
        if quote:
            if char == "\\" and quote == '"' and i + 1 < len(text):
                out.append(char)
                i += 1
                char = text[i]
            elif char == quote:
                quote = ""
        elif char == "\\" and i + 1 < len(text):
            out.append(char)
            i += 1
            char = text[i]
        elif char in "'\"":
            quote = char
        elif char == "#" and (not out or out[-1].isspace() or out[-1] in ";&|("):
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        out.append(char)
        i += 1
    return "".join(out)


def note_sleep(found, words, looped):
    """Record one `sleep` word list in `found`."""
    length = seconds(words)
    found["slept"] = True
    if length is None:
        found["unreadable"] = True
        return
    if looped:
        found["looped"] = True
        found["inner"] = max(found["inner"], length)
    else:
        found["top"] += length


def merge(found, payload):
    """Fold a `sh -c` payload's findings into its parent's.

    The payload runs in sequence with its parent, so its top-level sleeps add."""
    found["top"] += payload["top"]
    found["inner"] = max(found["inner"], payload["inner"])
    for key in ("slept", "unreadable", "looped"):
        found[key] = found[key] or payload[key]


def enter(stack, words):
    """Strip a segment's leading loop and prefix words, tracking loop frames.

    A frame is "cond" (a `while`/`until` condition, rerun every pass), "head" (a
    `for`/`select` list, evaluated once) or "body"; `do` turns the open frame
    into a body and `done` (handled by the caller) closes one."""
    while words:
        word = words[0]
        if word in ("while", "until"):
            stack.append("cond")
        elif word in ("for", "select"):
            stack.append("head")
            return []
        elif word == "do":
            if stack and stack[-1] != "body":
                stack[-1] = "body"
            else:
                stack.append("body")
        elif word not in PREFIXES:
            break
        words = words[1:]
    return words


def scan(text):
    """What a command's sleeps and backgrounding look like, as a dict.

    Keys: top (summed top-level sleep seconds), inner (longest sleep in a loop),
    looped (any sleep there, at any length), slept (any sleep at all),
    unreadable (a sleep length the gate cannot read), background, waits."""
    found = {"top": 0.0, "inner": 0.0, "looped": False, "slept": False,
             "unreadable": False, "background": [], "waits": False}
    stack = []
    # Comment text is prose; an `&` in it is not an operator.
    code = strip_comments(parser.strip_heredocs(text))
    for segment, operator in parser.split_operators(code):
        try:
            words = shlex.split(segment, comments=True)
        except ValueError:
            continue
        words, _ = parser.cut_redirects(words)
        words = enter(stack, words)
        if words and words[0] == "done":
            stack = stack[:-1]
            words = words[1:]
        # `( ... ) &` leaves an empty segment between the `)` and the `&`.
        if operator.startswith("&") and not operator.startswith("&&"):
            found["background"].append(segment or "( ... )")
        words = unwrap(parser.lead(words))
        if not words:
            continue
        name = os.path.basename(words[0])
        found["waits"] = found["waits"] or name == "wait"
        if name == "sleep":
            note_sleep(found, words, any(frame != "head" for frame in stack))
        body = parser.shell_body(words[1:]) if name in parser.SHELLS else None
        if body is not None:
            merge(found, scan(body))
    return found


def limit_ms(timeout):
    """Bash's time limit in ms, at most the host's ceiling; no usable number is the default."""
    usable = (isinstance(timeout, (int, float)) and not isinstance(timeout, bool)
              and math.isfinite(timeout) and timeout > 0)
    return min(timeout, MAX_TIMEOUT_MS) if usable else DEFAULT_TIMEOUT_MS


def verdict(command, timeout):
    """The reason to block, or None. `timeout` is Bash's parameter in ms."""
    if "sleep" not in command and "&" not in command:
        return None
    found = scan(command)
    if found["slept"] and TASK_OUTPUT.search(command):
        return ("Blocked: this sleeps and then reads a background task's output file. "
                "The harness notifies you when that task finishes; end your turn and read the file then.")
    if found["unreadable"]:
        return ("Blocked: sleeping for a length the gate cannot read can hold the session for minutes. "
                "Write the length as a number of 5 s or less. " + WAIT)
    if found["top"] > SHORT or found["inner"] > SHORT:
        length = found["top"] if found["top"] > SHORT else found["inner"]
        return f"Blocked: sleeping {length:g} s holds the session and learns nothing. {WAIT}"
    limit = limit_ms(timeout)
    if found["looped"] and limit > DEFAULT_TIMEOUT_MS:
        return (f"Blocked: this polls with a sleep in a loop under a {limit / 1000:g} s time limit, "
                f"so it can hold the session that long. {WAIT}")
    if found["background"] and not found["waits"]:
        shown = found["background"][0]
        shown = shown if len(shown) <= 80 else shown[:77] + "..."
        return ("Blocked: `" + shown + " &` starts a process the harness cannot see: nothing "
                "reports when it ends, and the teardown gate cannot stop it. Run it as its own Bash "
                "call with run_in_background: true; to run commands in parallel inside one call, end "
                "the command with `wait`.")
    return None


def main():
    repo = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    config = load("colloid_config", "config.py")
    settings = config.load(os.path.join(repo, ".agents", "config.json"))
    if not config.read(settings, "hooks.wait_gate.enabled", True):
        return 0
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        return 0
    if not isinstance(payload, dict) or payload.get("run_in_background"):
        return 0
    command = payload.get("command")
    if not isinstance(command, str) or not command.strip():
        return 0
    reason = verdict(command, payload.get("timeout"))
    if not reason:
        return 0
    print(reason, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())

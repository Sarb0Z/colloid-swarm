#!/usr/bin/env python3
"""Decide whether a shell command waits blind, and say what to do instead.

Input  (stdin JSON): {"command": "<shell command>", "run_in_background": bool}
Output: exit 2 and the remedy on stderr when a rule fires; exit 0 otherwise.

A foreground `sleep` holds the session and learns nothing; a bare `&` starts a
process the host cannot see, so nothing reports when it ends and the agent
falls back to sleeping and tailing its log. Three shapes are refused:

* sleeps longer than SHORT seconds, summed over the top level, or any single
  one inside a loop body or an `sh -c` payload;
* any sleep in a command that reads a host task's output file, which the host
  already reports on completion;
* a segment backgrounded with `&` in a command that never runs `wait`.

A short sleep passes: `kill 123; sleep 2` waits for a port to free, and
`until curl -sf ...; do sleep 2; done` ends the moment the condition holds.
Heredoc bodies are data, as in guard-destructive.
"""

import importlib.util
import json
import os
import re
import shlex
import sys

SHORT = 5.0
TASK_OUTPUT = re.compile(r"/tasks/[A-Za-z0-9_-]+\.output\b")
DURATION = re.compile(r"^(\d+(?:\.\d*)?|\.\d+)([smhd]?)$")
SCALE = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}
WRAPPERS = {"timeout", "gtimeout", "nice", "stdbuf"}
PREFIXES = {"then", "else", "elif", "{", "}", "!", "time", "nohup", "command", "builtin", "exec"}

WAIT = """Pick the wait that ends when the thing happens:
- A background shell or subagent you started: end your turn. The harness re-invokes you when it finishes; report then.
- A process you are about to start (tests, a build, a server): run it as its own Bash call with run_in_background: true. You are notified when it exits, and TaskStop stops it.
- A condition (a port answers, a file appears): poll briefly under a cap, e.g. timeout 120 bash -c 'until curl -sf http://localhost:3000 >/dev/null; do sleep 2; done'.
- CI or a deploy: gh run watch <id> --exit-status with run_in_background: true.
Sleeps of 5 s or less pass."""


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


def scan(text, nested=False):
    """(top-level sleep seconds, longest sleep in a loop or payload, backgrounded, waits)."""
    top, inner, background, waits, depth = 0.0, 0.0, [], False, 0
    # Comment text is prose; an `&` in it is not an operator.
    code = strip_comments(parser.strip_heredocs(text))
    for segment, operator in parser.split_operators(code):
        try:
            words = shlex.split(segment, comments=True)
        except ValueError:
            continue
        words, _ = parser.cut_redirects(words)
        while words and words[0] in PREFIXES | {"do"}:
            depth += words.pop(0) == "do"
        if words and words[0] == "done":
            depth = max(0, depth - 1)
            words = words[1:]
        # `( ... ) &` leaves an empty segment between the `)` and the `&`.
        if operator.startswith("&") and not operator.startswith("&&"):
            background.append(segment or "( ... )")
        words = unwrap(parser.lead(words))
        if not words:
            continue
        name = os.path.basename(words[0])
        if name == "wait":
            waits = True
        if name == "sleep":
            length = seconds(words) or 0.0
            if depth or nested:
                inner = max(inner, length)
            else:
                top += length
        if name in parser.SHELLS and "-c" in words and words.index("-c") + 1 < len(words):
            _, deeper, _, _ = scan(words[words.index("-c") + 1], nested=True)
            inner = max(inner, deeper)
    return top, inner, background, waits


def verdict(command):
    """The reason to block, or None."""
    if "sleep" not in command and "&" not in command:
        return None
    top, inner, background, waits = scan(command)
    if (top or inner) and TASK_OUTPUT.search(command):
        return ("Blocked: this sleeps and then reads a background task's output file. "
                "The harness notifies you when that task finishes; end your turn and read the file then.")
    if top > SHORT or inner > SHORT:
        length = top if top > SHORT else inner
        return f"Blocked: sleeping {length:g} s holds the session and learns nothing. {WAIT}"
    if background and not waits:
        shown = background[0] if len(background[0]) <= 80 else background[0][:77] + "..."
        return ("Blocked: `" + shown + " &` starts a process the harness cannot see, so nothing "
                "reports when it ends and the teardown check cannot stop it. Run it as its own Bash "
                "call with run_in_background: true. To run commands in parallel inside one call, end "
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
    reason = verdict(command)
    if not reason:
        return 0
    print(reason, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Run a Playwright MCP server on its own copy of the synced browser profile.

usage: playwright-session.py COMMAND [ARG...] --config FILE [ARG...]

A browser profile admits one browser at a time, so two sessions on one
profile directory lock each other out. When FILE names a `userDataDir`, this
launcher copies the cookie store and Chrome's `Local State` from that
directory into a private temporary directory, runs COMMAND against a config
that points at the copy, and deletes the copy when COMMAND ends. A config
without `userDataDir` runs unchanged: the generator marks it `isolated`.
"""

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# What a profile needs for Chrome to read its cookies. Caches stay behind.
COPIED = ("Default/Cookies", "Local State")
# Chrome's helpers can outlive the server for a moment after it exits.
GRACE_SECONDS = 5


def private_config(command, scratch):
    """COMMAND with --config redirected to a copy-backed config in `scratch`."""
    if "--config" not in command or command.index("--config") + 1 >= len(command):
        raise SystemExit("playwright-session: the command needs --config FILE")
    at = command.index("--config") + 1
    config = json.loads(Path(command[at]).read_text())
    source = config.get("browser", {}).get("userDataDir")
    if source is None:
        return command
    copy = scratch / "profile"
    (copy / "Default").mkdir(parents=True)
    copy.chmod(0o700)
    (copy / "Default").chmod(0o700)
    for relative in COPIED:
        original = Path(source) / relative
        if original.is_file():
            shutil.copy2(original, copy / relative)
    config["browser"]["userDataDir"] = str(copy)
    private = scratch / "playwright.json"
    private.write_text(json.dumps(config))
    return command[:at] + [str(private)] + command[at + 1:]


def main(command):
    if not command:
        raise SystemExit(__doc__)
    scratch = Path(tempfile.mkdtemp(prefix="playwright-session-"))
    child = None

    def forward(number, _frame):
        if child is None:
            sys.exit(128 + number)
        os.killpg(child.pid, number)

    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(number, forward)
    try:
        # Its own process group, so one signal reaches the server and Chrome.
        child = subprocess.Popen(private_config(command, scratch), start_new_session=True)

        status = child.wait()
    finally:
        if child is not None:
            _end_group(child.pid)
        shutil.rmtree(scratch)
    return status if status >= 0 else 128 - status


def _group_alive(pgid):
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    return True


def _end_group(pgid):
    """Stop what the server left running, so nothing holds the copy open."""
    if not _group_alive(pgid):
        return
    os.killpg(pgid, signal.SIGTERM)
    deadline = time.monotonic() + GRACE_SECONDS
    while _group_alive(pgid) and time.monotonic() < deadline:
        time.sleep(0.1)
    if _group_alive(pgid):
        os.killpg(pgid, signal.SIGKILL)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Trust this repository's Codex hooks.

Editing hooks.json invalidates the recorded hash for every hook it changes, and
a hook whose hash no longer matches stops running until it is approved again.
The sync script rewrites hooks.json, so without this step a sync silently
disarms the hooks it just deployed.

Codex computes each hook's hash itself and reports it through the app-server
`hooks/list` method, along with the `[hooks.state]` key it stores trust under.
Taking the hash from Codex rather than recomputing it means the private
normalization rules stay Codex's business.
"""

import json
import os
import re
import subprocess
import sys
import tempfile

STATE = re.compile(r'\[hooks\.state\."((?:[^"\\]|\\.)*)"\]\n((?:(?!\[).*\n)*)')


def hooks_for(repo):
    """Ask Codex which hooks it discovers in repo, and what it hashes them to."""
    try:
        proc = subprocess.Popen(
            ["codex", "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1)
    except (FileNotFoundError, OSError):
        return None, "codex not on PATH"

    def send(obj):
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    try:
        send({"id": 0, "method": "initialize",
              "params": {"clientInfo": {"name": "colloid-sync-codex", "version": "1"}}})
        send({"method": "initialized"})
        send({"id": 1, "method": "hooks/list", "params": {"cwds": [repo]}})
        reply = None
        for _ in range(200):
            line = proc.stdout.readline()
            if not line:
                break
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("id") == 1:
                reply = msg
                break
    except (BrokenPipeError, OSError) as error:
        return None, f"app-server not reachable: {error}"
    finally:
        proc.terminate()

    if reply is None:
        return None, "app-server returned no answer to hooks/list"
    if "error" in reply:
        return None, f"hooks/list failed: {json.dumps(reply['error'])[:200]}"

    # Only this repository's own hooks. A plugin or another workspace keeps
    # whatever trust the operator already gave it.
    prefix = os.path.join(repo, ".codex", "hooks.json") + ":"
    wanted = {}
    for entry in reply["result"]["data"]:
        for hook in entry.get("hooks", []):
            if hook["key"].startswith(prefix):
                wanted[hook["key"]] = hook["currentHash"]
    return wanted, None


def upsert(text, wanted):
    """Replace the trust block for each key, append the ones with no block."""
    seen = set()

    def replace(match):
        key = match.group(1)
        if key not in wanted:
            return match.group(0)
        seen.add(key)
        return f'[hooks.state."{key}"]\ntrusted_hash = "{wanted[key]}"\nenabled = true\n'

    out = STATE.sub(replace, text)
    missing = [k for k in wanted if k not in seen]
    if missing:
        if out and not out.endswith("\n"):
            out += "\n"
        for key in missing:
            out += f'\n[hooks.state."{key}"]\ntrusted_hash = "{wanted[key]}"\nenabled = true\n'
    return out


def main():
    repo = os.path.realpath(sys.argv[1] if len(sys.argv) > 1 else ".")
    wanted, problem = hooks_for(repo)
    if problem:
        print(f"sync-codex: hooks left untrusted — {problem}", file=sys.stderr)
        return 0
    if not wanted:
        print("sync-codex: Codex discovered no hooks for this repository", file=sys.stderr)
        return 0

    path = os.path.join(os.path.expanduser("~"), ".codex", "config.toml")
    try:
        with open(path, encoding="utf-8") as f:
            before = f.read()
    except FileNotFoundError:
        before = ""
    after = upsert(before, wanted)
    if after == before:
        return 0

    # The global config carries every project's settings; never write it in place.
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(after)
        os.replace(tmp, path)
    except BaseException:
        os.path.exists(tmp) and os.unlink(tmp)
        raise
    print(f"trusted {len(wanted)} Codex hook(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

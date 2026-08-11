#!/usr/bin/env python3
"""Trust this repository's Codex hooks.

Editing hooks.json changes the hash Codex computes for every hook it touched,
and a hook whose recorded hash differs from the computed one stops running. The
sync script rewrites hooks.json, so without this step a sync disarms the hooks
it just deployed.

Codex computes those hashes itself and reports them through the app-server
`hooks/list` method, together with the `[hooks.state]` key it files trust
under. Taking the hash from Codex leaves the normalization rules on Codex's
side of the line.

Discovery is gated on the project being trusted, so the project entry is
written first — without it Codex reports no hooks at all and there is nothing
to trust.

Usage: trust-hooks.py <repo> [--config PATH] [--dry-run]
"""

import json
import os
import re
import select
import subprocess
import sys
import tempfile
import time
import tomllib

TIMEOUT = 30.0

# A TOML table header plus the lines under it, up to the next header. The key
# is matched with its escapes intact, so it compares directly against a key
# rendered by `quoted()`. Anything trailing the header — a comment the operator
# wrote — is captured so it can be put back. Missing a block is not benign: the
# key is then appended a second time and the file stops parsing.
# The body runs to the next header. Its guard rejects horizontal space only:
# `\s*` would match the newline of a trailing blank line and stop short of it,
# leaving that line outside the match for the rewrite to add another one to,
# every run, forever.
BLOCK = r'\[%s\."((?:[^"\\]|\\.)*)"\]([^\r\n]*)\r?\n((?:(?![^\S\n]*\[).*\r?\n)*)'
STATE = re.compile(BLOCK % "hooks\\.state")
PROJECT = re.compile(BLOCK % "projects")


def quoted(value):
    """Render a TOML basic string. JSON's escaping is a subset of TOML's."""
    return json.dumps(value)


class Fault(Exception):
    """Codex is present but did not answer usefully — never silent."""


def ask_codex(repo):
    """Return {state key: current hash} for repo's own hooks, or None if no codex."""
    try:
        proc = subprocess.Popen(
            ["codex", "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1)
    except (FileNotFoundError, OSError):
        return None

    def send(obj):
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    reply = None
    try:
        send({"id": 0, "method": "initialize",
              "params": {"clientInfo": {"name": "scaffold-trust-hooks", "version": "1"}}})
        send({"method": "initialized"})
        send({"id": 1, "method": "hooks/list", "params": {"cwds": [repo]}})
        deadline = time.monotonic() + TIMEOUT
        while reply is None:
            left = deadline - time.monotonic()
            if left <= 0:
                raise Fault(f"app-server did not answer hooks/list within {TIMEOUT:.0f}s")
            if not select.select([proc.stdout], [], [], left)[0]:
                continue
            line = proc.stdout.readline()
            if not line:
                raise Fault("app-server closed the connection before answering")
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if message.get("id") == 1:
                reply = message
    except (BrokenPipeError, OSError) as error:
        raise Fault(f"app-server not reachable: {error}") from error
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)     # it shares the config file; do not race its exit
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()

    if "error" in reply:
        raise Fault(f"hooks/list failed: {json.dumps(reply['error'])[:200]}")
    data = (reply.get("result") or {}).get("data")
    if not isinstance(data, list):
        raise Fault("hooks/list returned no data array")

    # Only this repository's hooks. Another workspace or a marketplace plugin
    # keeps whatever trust the operator gave it.
    prefix = os.path.join(repo, ".codex", "hooks.json") + ":"
    found = {}
    for entry in data:
        if not isinstance(entry, dict):
            continue
        for note in entry.get("warnings") or []:
            print(f"trust-hooks: Codex warns: {note}", file=sys.stderr)
        for note in entry.get("errors") or []:
            print(f"trust-hooks: Codex error: {note}", file=sys.stderr)
        for hook in entry.get("hooks") or []:
            key, digest = hook.get("key"), hook.get("currentHash")
            if isinstance(key, str) and isinstance(digest, str) and key.startswith(prefix):
                found[key] = digest
    return found


def declared(repo):
    """How many hooks this repo's hooks.json declares, for a coverage check."""
    try:
        with open(os.path.join(repo, ".codex", "hooks.json"), encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return None
    return sum(len(group.get("hooks") or [])
               for groups in (doc.get("hooks") or {}).values()
               for group in groups)


def block(table, key, fields):
    return f"[{table}.{quoted(key)}]\n" + "".join(f"{k} = {v}\n" for k, v in fields) + "\n"


def upsert(text, pattern, table, wanted):
    """Set the given fields under each key, preserving any others already there."""
    escaped = {quoted(k)[1:-1]: v for k, v in wanted.items()}
    seen = set()
    # The body group needs a line terminator, so a file whose last line lacks
    # one would hide its final block from the match.
    if text and not text.endswith("\n"):
        text += "\n"

    def replace(match):
        key = match.group(1)
        if key not in escaped:
            return match.group(0)
        seen.add(key)
        fields = dict(escaped[key])
        kept = []
        for line in match.group(3).splitlines():
            name = line.split("=", 1)[0].strip()
            if name and name not in fields and line.strip():
                kept.append(line.rstrip("\r"))
        body = "".join(f"{k} = {v}\n" for k, v in fields.items())
        body += "".join(line + "\n" for line in kept)
        return f"[{table}.\"{key}\"]{match.group(2)}\n{body}\n"

    out = pattern.sub(replace, text)
    missing = [k for k in wanted if quoted(k)[1:-1] not in seen]
    if missing:
        if out and not out.endswith("\n"):
            out += "\n"
        for key in missing:
            out += block(table, key, wanted[key].items())
    return out


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def store(path, text, dry_run):
    """Never hand the operator a config that does not parse."""
    try:
        tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        raise Fault(f"refusing to write unparseable config: {error}")
    if dry_run:
        return
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".trust-hooks-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    dry_run = "--dry-run" in flags
    config = next((a.split("=", 1)[1] for a in flags if a.startswith("--config=")),
                  os.path.join(os.path.expanduser("~"), ".codex", "config.toml"))
    # The caller's path, not the resolved one: Codex keys trust by the literal
    # cwd it was handed, so resolving symlinks files trust under a name it
    # never looks up.
    repo = os.path.abspath(args[0] if args else ".")

    try:
        # Discovery is gated on project trust, so this has to land first.
        text = load(config)
        trusted = upsert(text, PROJECT, "projects", {repo: {"trust_level": '"trusted"'}})
        if trusted != text:
            store(config, trusted, dry_run)
            print(f"trusted project {repo}")

        found = ask_codex(repo)
        if found is None:
            print("trust-hooks: codex not on PATH — hooks left untrusted", file=sys.stderr)
            return 0
        if not found:
            raise Fault("Codex discovered no hooks for this repository")
        want = declared(repo)
        if want is not None and want != len(found):
            print(f"trust-hooks: Codex discovered {len(found)} hook(s), "
                  f"hooks.json declares {want}", file=sys.stderr)

        text = load(config)
        after = upsert(text, STATE, "hooks.state",
                       {k: {"trusted_hash": quoted(v), "enabled": "true"}
                        for k, v in found.items()})
        if after != text:
            store(config, after, dry_run)
            print(f"trusted {len(found)} Codex hook(s)")
    except Fault as error:
        print(f"trust-hooks: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

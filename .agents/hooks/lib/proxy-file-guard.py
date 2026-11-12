#!/usr/bin/env python3
"""Decide whether a tool call names the env file of a configured Scrapling proxy.

Usage: proxy-file-guard.py <repo>    # normalized payload on stdin

The payload carries `tool_name` and the inputs the decision reads: `file_path`
(Read), `path` (Grep) and `command` (a shell). Exit 2 with the reason on stderr
denies; exit 0 allows. The env file is never opened and never quoted: the reason
names the proxy only.

A config that does not load, a `scrapling.proxies` that `load_names` refuses or
a payload that is not JSON each print one stderr line and allow, since a hook
that must not block on its own failure.
"""

import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import config  # noqa: E402


def load_proxy_module(repo):
    path = os.path.join(repo, ".agents", "lib", "proxy.py")
    spec = importlib.util.spec_from_file_location("colloid_proxy", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def spellings(env_file):
    """The absolute path, and under $HOME its `~/`, `$HOME/` and `${HOME}/` forms."""
    path = str(env_file)
    found = {path}
    home = os.path.expanduser("~").rstrip("/")
    if home and path.startswith(home + "/"):
        rest = path[len(home) + 1:]
        found |= {f"~/{rest}", f"$HOME/{rest}", f"${{HOME}}/{rest}"}
    return found


def names_file(payload, env_file, forms):
    """True when a path input resolves to the file or any input text carries a spelling."""
    for key in ("file_path", "path"):
        value = payload.get(key)
        if isinstance(value, str) and value:
            if os.path.normpath(os.path.expanduser(value)) == os.path.normpath(str(env_file)):
                return True
    texts = [payload.get(key) for key in ("file_path", "path", "command")]
    return any(form in text for text in texts if isinstance(text, str) for form in forms)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("proxy-file-guard.py: usage: proxy-file-guard.py <repo>")
    repo = sys.argv[1]
    config_path = os.path.join(repo, ".agents", "config.json")
    proxy = load_proxy_module(repo)
    try:
        names = proxy.load_names(config_path)
    except proxy.ProxyError as error:
        print(f"proxy-file-guard: {error}; the guard allows this call", file=sys.stderr)
        return 0
    if not names:
        return 0
    settings = config.load(config_path)
    if not config.read(settings, "hooks.proxy_file_guard.enabled", True):
        return 0
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        print("proxy-file-guard: the payload is not JSON; the guard allows this call", file=sys.stderr)
        return 0
    if not isinstance(payload, dict):
        return 0
    for name, named in names.items():
        if names_file(payload, named.env_file, spellings(named.env_file)):
            print(f"proxy-file-guard: this call names the env file of proxy '{name}', which holds its password. "
                  f'Pass proxy="{name}" to the Scrapling tools instead of reading the file.', file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

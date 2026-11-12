#!/usr/bin/env python3
"""Decide whether a tool call names the env file of a configured Scrapling proxy.

Usage: proxy-file-guard.py <repo>    # normalized payload on stdin

The payload carries `tool_name` and the inputs the decision reads: `file_path`
(Read), `path` and `output_mode` (Grep) and `command` (a shell). Exit 2 with the reason on stderr
denies; exit 0 allows. The env file is never opened and never quoted: the reason
names the proxy only.

A config that does not load, a `scrapling.proxies` that `load_names` refuses or
a payload that is not JSON each print one stderr line and allow, since a hook
that must not block on its own failure.
"""

import importlib.util
import json
import os
import re
import shlex
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


SEARCH_TOOLS = {"rg", "grep", "egrep", "fgrep", "ag", "ack"}
SEPARATORS = set(";&|()")


def expand(word):
    """The word with `~`, `$HOME` and `${HOME}` expanded and the path normalized."""
    home = os.path.expanduser("~").rstrip("/")
    word = word.replace("${HOME}", home).replace("$HOME", home)
    return os.path.normpath(os.path.expanduser(word))


def resolved(path):
    """The real path when it exists, else None."""
    return os.path.realpath(path) if os.path.exists(path) else None


def is_file(value, env_file):
    """True when the path, spelled any way, is the env file or a link to it."""
    path = expand(value)
    real = resolved(path)
    return path == os.path.normpath(env_file) or (real is not None and real == resolved(env_file))


def is_folder(value, env_file):
    """True when the path is the env file's folder, or an ancestor of it strictly below $HOME."""
    home = os.path.expanduser("~").rstrip("/")
    folder = os.path.dirname(os.path.normpath(env_file))
    for path in {expand(value), resolved(expand(value))} - {None}:
        for target in {folder, resolved(folder)} - {None}:
            if path == target:
                return True
            if path.startswith(home + "/") and target.startswith(path + "/"):
                return True
    return False


def words_of(command):
    """The command's words, grouped by segment, unquoted. Punctuation ends a segment."""
    segments = []
    for line in command.splitlines():
        lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
        lexer.commenters = ""
        lexer.whitespace_split = True
        try:
            tokens = list(lexer)
        except ValueError:
            tokens = line.split()
        segment = []
        for token in tokens:
            if set(token) <= SEPARATORS:
                segments.append(segment)
                segment = []
            elif not set(token) <= set("<>"):
                segment.append(token)
        segments.append(segment)
    return [segment for segment in segments if segment]


def candidates(word):
    """A word, and the value after the `=` of an option such as `--file=PATH`."""
    return [word, word.split("=", 1)[1]] if word.startswith("-") and "=" in word else [word]


def search_tool(segment):
    """The segment's command name, past leading VAR=value assignments."""
    for word in segment:
        if not re.match(r"[A-Za-z_][A-Za-z0-9_]*=", word):
            return os.path.basename(word)
    return ""


def names_file(payload, env_file, forms):
    """True when the call names the file, or searches its folder in a way that prints it."""
    env_file = str(env_file)
    for key in ("file_path", "path"):
        value = payload.get(key)
        if isinstance(value, str) and value and is_file(value, env_file):
            return True
    path = payload.get("path")
    if (payload.get("output_mode") == "content" and isinstance(path, str) and path
            and is_folder(path, env_file)):
        return True
    command = payload.get("command")
    if isinstance(command, str) and command:
        for segment in words_of(command):
            searching = search_tool(segment) in SEARCH_TOOLS
            for word in segment:
                for candidate in candidates(word):
                    if is_file(candidate, env_file) or (searching and is_folder(candidate, env_file)):
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

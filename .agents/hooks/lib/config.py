#!/usr/bin/env python3
"""Read scaffold toggles out of .agents/policy.json and .agents/config.json.

Usage: config.py <config-path> <dotted.key>=<default> ...

Two files, one shape. `policy.json` beside the config path is tracked: it holds
what the repository decides for everyone who clones it — a hook it runs
without, the scripts its publish guard must ask about. `config.json` is
ignored: it holds one operator's taste on one machine, and a key it states
overrides the same key in policy. A hook reads the layered result and never
needs to know which file said so.

Prints one line per key, in the order given. A `true` or `false` default makes
the key a toggle and prints `yes` or `no`, so the caller compares a word instead
of reasoning about JSON. Any other default prints as it stands.

A toggle that defaults on is off only when the files say exactly `false`, and a
toggle that defaults off is on only when they say exactly `true`. An absent
file, unreadable JSON, or a key whose parent is not an object all yield the
default: the files state the exceptions, and their absence is not one. A file
that exists but cannot be read as a JSON object is reported on stderr, once per
process however often it is read, because its exceptions vanish with it: a hook
the repository turned off comes back on, and a script the publish guard must
ask about is no longer listed. `unparsed` names such files, so a caller whose
safety rests on their contents can fail safe instead of falling back.
"""

import json
import os
import sys


def default_of(text):
    if text == "true":
        return True
    if text == "false":
        return False
    return text


# (path, mtime, size) -> (document, parsed): each version of a file is read
# and reported once per process.
_documents = {}


def _version(path):
    try:
        status = os.stat(path)
    except FileNotFoundError:
        return None
    return path, status.st_mtime_ns, status.st_size


def _read_json(path):
    return _entry(path)[0]


def _entry(path):
    version = _version(path)
    if version is None:
        return {}, True
    if version not in _documents:
        _documents[version] = _parse(path)
    return _documents[version]


def _parse(path):
    try:
        with open(path, encoding="utf-8") as source:
            document = json.load(source)
    except FileNotFoundError:
        return {}, True
    except (OSError, ValueError) as error:
        print(f"config.py: {path} is unreadable ({error}); every key in it falls back to its default",
              file=sys.stderr)
        return {}, False
    if not isinstance(document, dict):
        print(f"config.py: {path} holds {json.dumps(document)[:40]}, not a JSON object; "
              "every key in it falls back to its default", file=sys.stderr)
        return {}, False
    return document, True


def _overlay(base, top):
    """Deep-merge dicts; a scalar or list in `top` replaces the base value."""
    merged = dict(base)
    for key, value in top.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = _overlay(merged[key], value)
        else:
            merged[key] = value
    return merged


def _paths(config_path):
    return os.path.join(os.path.dirname(config_path), "policy.json"), config_path


def load(config_path):
    """The layered settings: policy.json under config.json, both optional."""
    policy_path, config_path = _paths(config_path)
    return _overlay(_read_json(policy_path), _read_json(config_path))


def unparsed(config_path):
    """The policy and config files that exist but do not read as a JSON object."""
    return [path for path in _paths(config_path) if not _entry(path)[1]]


def read(settings, path, default):
    node = settings
    for name in path.split("."):
        if not isinstance(node, dict) or name not in node:
            return default
        node = node[name]
    if isinstance(default, bool):
        return node is not False if default else node is True
    return node


def main():
    if len(sys.argv) < 3:
        raise SystemExit("config.py: usage: config.py <config-path> <key>=<default> ...")
    settings = load(sys.argv[1])
    for argument in sys.argv[2:]:
        key, _, raw = argument.partition("=")
        default = default_of(raw)
        value = read(settings, key, default)
        print(("yes" if value else "no") if isinstance(default, bool) else value)
    return 0


if __name__ == "__main__":
    sys.exit(main())

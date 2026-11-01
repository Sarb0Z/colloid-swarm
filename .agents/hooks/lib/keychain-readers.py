#!/usr/bin/env python3
"""Decide whether a shell command will read the macOS login keychain.

Usage: keychain-readers.py <config-path>    # the command on stdin

Exit 0 with two lines on stdout, the reader's name and the command line it
stands on, when the command reads the keychain; exit 3 when it does not. Any
other exit is a failure of this script. The command travels on stdin because a
large heredoc would push an argument past ARG_MAX.

macOS's keychain dialog names only the program that asks ("supabase wants to
access key ..."), never the command line or the session behind it. A command is
a reader when it runs one of the built-in readers below or a program a
repository lists under `hooks.keychain_notice.readers` in policy.json: a script
of its own that calls `security`, for example.

Matching is textual, so a missed notice is rarer than an extra one. A reader
counts when its name stands as a word of its own, alone or as the last part of
a path: `python3 scripts/environments.py` and `npx supabase@latest` match, and
`supabase-helper` and `cd supabase/migrations` do not.
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # noqa: E402

NOT_A_READER = 3

# Programs that read the login keychain by themselves: the Supabase CLI keeps
# its access token there, and `security` reads any password it is asked for,
# with options such as `-q` allowed before the subcommand.
BUILT_IN = (
    ("supabase", r"supabase"),
    ("security find-generic-password", r"security(?:\s+-\S+)*\s+find-generic-password"),
    ("security find-internet-password", r"security(?:\s+-\S+)*\s+find-internet-password"),
)

# Before a reader: a line start, whitespace, a shell operator, a quote or a
# path separator. After it: a line end, whitespace, a shell operator, a quote,
# an npx version pin (`@latest`) or a line-continuation backslash.
BEFORE = r"(?:^|[\s;&|(`'\"/=])"
AFTER = r"(?=$|[\s;&|)`'\"@\\])"


def declared(settings):
    """The repository's own readers, by name; anything that is not a name is reported."""
    names = config.read(settings, "hooks.keychain_notice.readers", [])
    if not isinstance(names, list):
        print("keychain-readers: hooks.keychain_notice.readers must be a list of program names; ignoring it",
              file=sys.stderr)
        return []
    valid = [name.strip() for name in names if isinstance(name, str) and name.strip()]
    if len(valid) != len(names):
        print("keychain-readers: hooks.keychain_notice.readers holds an entry that is not a program name; "
              "ignoring that entry", file=sys.stderr)
    return [(name, re.escape(name)) for name in valid]


def reader(command, readers):
    """The first reader the command runs and the line it starts on, or None."""
    for name, pattern in readers:
        match = re.search(BEFORE + "(" + pattern + ")" + AFTER, command, re.M)
        if match:
            start = command.rfind("\n", 0, match.start(1)) + 1
            end = command.find("\n", start)
            return name, command[start:] if end < 0 else command[start:end]
    return None


def main():
    if len(sys.argv) != 2:
        print("keychain-readers.py: usage: keychain-readers.py <config-path>  # command on stdin", file=sys.stderr)
        return 2
    found = reader(sys.stdin.read(), BUILT_IN + tuple(declared(config.load(sys.argv[1]))))
    if found is None:
        return NOT_A_READER
    print(found[0])
    print(found[1].strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())

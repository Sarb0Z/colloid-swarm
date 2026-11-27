#!/usr/bin/env python3
"""Build the device policy payload from the repository's own sources.

The payload is generated, never checked in, so the device tier cannot drift
from what the repository tests. The prose is the body of
`.agents/claude/output-style.md`, the same text the project output style and
the Codex developer instructions carry, so every tier says one thing.
`permissions.ask` comes from `.agents/claude/settings.json`, which
`test-guard-publish.py` already holds to the guard's plain forms in both
directions, and so does `includeGitInstructions`: the style sets when to
commit, so the host's own git section, which says otherwise, is off in every
repository the appended style reaches.

An optional account-limits file adds managed settings for named signed-in
accounts, such as `{"guest@example.com": {"deniedModels": ["fable"]}}`. It is
machine-local, never committed, because the accounts on one machine are not
the scaffold's. Each listed account gets its own full payload under
`accounts/<email>.json`, which the helper serves when that account is the one
signed in to the profile Claude Code starts with.

Usage: build.py <output-directory> [<account-limits.json>]
"""

import json
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SETTINGS = os.path.join(HERE, "..", "settings.json")
STYLE = os.path.join(HERE, "..", "output-style.md")
HOOK_LIB = os.path.join(HERE, "..", "..", "hooks", "lib")

# The only keys Claude Code accepts from a policy helper's stdout.
ENVELOPE_KEYS = {"managedSettings", "claudeMd", "appendSystemPrompt"}
# The managed settings an account entry may set. A key outside this set is
# refused, so a typo cannot build a payload that restricts nothing, and an
# entry cannot replace a shared key such as `permissions` wholesale.
ACCOUNT_KEYS = {"deniedModels"}
# The email is a file name the helper looks up, so it may not name a path or
# a hidden file, which the helper never serves.
EMAIL = re.compile(r"[a-z0-9][a-z0-9._%+-]*@[a-z0-9-]+(\.[a-z0-9-]+)+")


def payload():
    # The style is read the way every other consumer reads it; the system
    # prompt takes its prose only, without the frontmatter.
    sys.path.insert(0, HOOK_LIB)
    import output_style
    prose = output_style.body(STYLE)
    with open(SETTINGS, encoding="utf-8") as handle:
        settings = json.load(handle)
    ask = settings["permissions"]["ask"]
    if not prose:
        raise SystemExit("build: output-style.md has no body")
    if "Artifact" not in ask:
        raise SystemExit("build: settings.json permissions.ask does not gate Artifact")
    if settings.get("includeGitInstructions") is not False:
        raise SystemExit("build: settings.json must set includeGitInstructions to false")
    return {"appendSystemPrompt": prose,
            "managedSettings": {"permissions": {"ask": ask}, "includeGitInstructions": False}}


def account_limits(path):
    with open(path, encoding="utf-8") as handle:
        limits = json.load(handle)
    if not isinstance(limits, dict):
        raise SystemExit(f"build: {path} must map account emails to managed settings")
    accounts = {}
    for email, settings in limits.items():
        normalized = email.strip().lower()
        if not EMAIL.fullmatch(normalized):
            raise SystemExit(f"build: {path}: {email!r} is not an account email")
        if normalized in accounts:
            raise SystemExit(f"build: {path}: {email} is listed twice")
        if not isinstance(settings, dict) or not settings:
            raise SystemExit(f"build: {path}: {email} must map to a non-empty "
                             "object of managed settings")
        if set(settings) - ACCOUNT_KEYS:
            raise SystemExit(f"build: {path}: {email} sets "
                             f"{sorted(set(settings) - ACCOUNT_KEYS)}; an account "
                             f"may set only {sorted(ACCOUNT_KEYS)}")
        denied = settings["deniedModels"]
        if (not isinstance(denied, list) or not denied
                or not all(isinstance(model, str) and model.strip() for model in denied)):
            raise SystemExit(f"build: {path}: {email}: deniedModels must be a "
                             "non-empty list of model names, such as [\"fable\"]")
        accounts[normalized] = settings
    return accounts


def write(path, document):
    assert set(document) <= ENVELOPE_KEYS
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2)
        handle.write("\n")


def main():
    if len(sys.argv) not in (2, 3):
        raise SystemExit("usage: build.py <output-directory> [<account-limits.json>]")
    target = sys.argv[1]
    document = payload()
    accounts = account_limits(sys.argv[2]) if len(sys.argv) == 3 else {}
    os.makedirs(target, exist_ok=True)
    write(os.path.join(target, "policy.json"), document)
    # A rebuild replaces every account payload, so an account taken off the
    # limits file loses its restriction at the next install.
    # With no account listed the folder is gone, so an installer that copies
    # it has nothing to glob.
    account_dir = os.path.join(target, "accounts")
    if os.path.isdir(account_dir):
        shutil.rmtree(account_dir)
    if accounts:
        os.makedirs(account_dir)
    for email, settings in accounts.items():
        limited = dict(document, managedSettings={**document["managedSettings"], **settings})
        write(os.path.join(account_dir, f"{email}.json"), limited)
    print(f"build: {len(document['appendSystemPrompt'])} chars appended, "
          f"{len(document['managedSettings']['permissions']['ask'])} ask rules, "
          f"{len(accounts)} limited account(s)")


if __name__ == "__main__":
    main()

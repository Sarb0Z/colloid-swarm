#!/usr/bin/env python3
"""Decide whether a shell command is destructive, and say why.

Input  (stdin JSON): {"command": "<shell command>"}
Output: exit 2 and one line on stderr when a rule fires; exit 0 otherwise.

A substring cannot tell a command from the text of a command. Every rule here
reads tokens instead. `normalize` removes heredoc bodies, splits the text at
the shell operators, and tokenizes each segment with one quote layer stripped;
a rule then reads a command name, its flags, and its operands.

Two boundaries follow from that shape, and both are deliberate:

* A heredoc body is data. `bash <<EOF ... EOF` is therefore not inspected.
  The same rule stops `cat > file <<EOF` from blocking on file content, which
  is the traffic this hook actually carries.
* A segment with an unbalanced quote is dropped, not guessed at. The shell
  refuses such a segment too, so nothing that can run is skipped.

The threat model is an honest mistake by the model, not an adversary with a
shell. Obfuscation defeats this, and is meant to.
"""

import json
import os
import re
import shlex
import sys

# Command words, with redirection operators and their targets pulled aside.
# A rule reads `words` for what runs and `targets` for where output lands.
class Command:
    __slots__ = ("words", "targets")

    def __init__(self, words, targets):
        self.words = words
        self.targets = targets


SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
OPERATORS = ";\n&|()`"
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# `<<` opens a heredoc; `<<<` is a herestring and carries no body.
HEREDOC = re.compile(r"<<(?!<)-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def strip_heredocs(text):
    """Drop heredoc bodies, which are data rather than commands."""
    lines = text.split("\n")
    kept, index = [], 0
    while index < len(lines):
        line = lines[index]
        kept.append(line)
        index += 1
        for match in HEREDOC.finditer(line):
            delimiter = match.group(2)
            end = index
            while end < len(lines) and lines[end].strip() != delimiter:
                end += 1
            # No terminator means the match was not a heredoc opener.
            if end < len(lines):
                index = end + 1
    return "\n".join(kept)


def segments(text):
    """Split at the shell operators, honouring quotes and escapes."""
    found, current, quote, index = [], [], None, 0
    while index < len(text):
        char = text[index]
        if quote:
            current.append(char)
            if char == "\\" and quote == '"' and index + 1 < len(text):
                current.append(text[index + 1])
                index += 2
                continue
            if char == quote:
                quote = None
            index += 1
        elif char in "'\"":
            quote = char
            current.append(char)
            index += 1
        elif char == "\\" and index + 1 < len(text):
            # Includes a line continuation, which must not split the command.
            current.append(char)
            current.append(text[index + 1])
            index += 2
        elif char in OPERATORS:
            found.append("".join(current))
            current = []
            while index < len(text) and text[index] in OPERATORS:
                index += 1
        else:
            current.append(char)
            index += 1
    found.append("".join(current))
    return [segment for segment in (part.strip() for part in found) if segment]


def cut_redirects(words):
    """Separate redirection targets from the words that name the command."""
    kept, targets, index = [], [], 0
    while index < len(words):
        word = words[index]
        if word and word[0] in "<>":
            width = 1
        elif len(word) > 1 and word[0].isdigit() and word[1] == ">":
            width = 2
        else:
            kept.append(word)
            index += 1
            continue
        target = word[width:].lstrip("<>&")
        if not target and index + 1 < len(words):
            index += 1
            target = words[index]
        if target:
            targets.append(target)
        index += 1
    return kept, targets


def normalize(text, depth=0):
    """Every command the text runs, as tokens with one quote layer stripped."""
    commands = []
    for segment in segments(strip_heredocs(text)):
        try:
            words = shlex.split(segment, comments=True)
        except ValueError:
            continue
        words, targets = cut_redirects(words)
        if not words:
            continue
        commands.append(Command(words, targets))
        # `sh -c '<command>'` runs its argument. Read it as one.
        run = lead(words)
        if depth < 2 and run and base(run[0]) in SHELLS and "-c" in run:
            payload = run[run.index("-c") + 1:]
            if payload:
                commands.extend(normalize(payload[0], depth + 1))
    return commands


def base(word):
    return os.path.basename(word)


def lead(words):
    """The command words, past any environment prefix."""
    index = 0
    while index < len(words) and (
        ASSIGNMENT.match(words[index])
        or words[index] in ("sudo", "env", "command", "exec", "nohup", "time")
    ):
        index += 1
    return words[index:]


def parts(args):
    """Short-flag letters, long flags, and operands, honouring `--`."""
    letters, longs, operands, terminated = set(), set(), [], False
    for word in args:
        if terminated or not word.startswith("-") or word == "-":
            operands.append(word)
        elif word == "--":
            terminated = True
        elif word.startswith("--"):
            longs.add(word.split("=", 1)[0])
        else:
            letters.update(word[1:])
    return letters, longs, operands


GLOB = "*?["
HOMES = ("${HOME}", "$HOME")
BARE = {"/", "~", ".", "..", "*", "**", "./*", "../*", "~/*", ".*", "./.*", "../.*"}
# Scratch roots. A path under one of these is throwaway by construction, which
# is the whole reason a session writes there.
SCRATCH = ("/tmp", "/var/tmp", "/private/tmp", "/private/var/tmp", "/var/folders")


def under(path, root):
    """True when path sits at least one component below root."""
    return bool(root) and path.startswith(root.rstrip("/") + "/")


def broad(operand, project=""):
    """True when a recursive delete of this operand reaches past the agent's work.

    An absolute path is broad by default. Depth is not safety — `/Users/mac` is
    two components and `/var/lib/postgresql` is three, and neither is this
    session's to delete. Only two carve-outs are narrow enough to name: inside
    the project the agent is working in, and inside a scratch root.
    """
    path = operand.rstrip("/") or "/"
    for prefix in HOMES:
        if path == prefix or path.startswith(prefix + "/"):
            path = "~" + path[len(prefix):]
            break
    if path in BARE:
        return True
    if not (path.startswith("/") or path.startswith("~/")):
        # A relative path is the agent's own working tree, and its own call —
        # unless the glob can match `..`, which reaches out of it.
        name = path.rsplit("/", 1)[-1]
        return name.startswith(".") and any(char in name for char in GLOB)
    if path.startswith("~/"):
        path = os.path.expanduser(path)
    if under(path, project) or any(under(path, root) for root in SCRATCH):
        return False
    return True


def rule_rm(command, project=""):
    words = lead(command.words)
    if not words or base(words[0]) != "rm":
        return None
    letters, longs, operands = parts(words[1:])
    if not ({"r", "R"} & letters or "--recursive" in longs):
        return None
    if any(broad(operand, project) for operand in operands):
        return ("Recursive rm on a broad path. This is irreversible — confirm "
                "with the user, or narrow the path.")
    return None


# Git reads these before the subcommand, and each takes a separate value.
GIT_VALUED = {"-C", "-c", "--git-dir", "--work-tree", "--exec-path", "--namespace"}


def git_verb(words):
    """The git subcommand and its own arguments, past the global options."""
    index = 1
    while index < len(words):
        word = words[index]
        if word in GIT_VALUED:
            index += 2
        elif word.startswith("-"):
            index += 1
        else:
            return word, words[index + 1:]
    return None, []


def rule_git(command, project=""):
    words = lead(command.words)
    if not words or base(words[0]) != "git":
        return None
    verb, rest = git_verb(words)
    letters, longs, _ = parts(rest)
    if verb == "push" and ({"f"} & letters or {"--force", "--force-with-lease"} & longs):
        return "Force-push rewrites remote history. Confirm with the user before running."
    if verb == "reset" and "--hard" in longs:
        return "git reset --hard discards work irreversibly. Confirm with the user, or use stash/branch."
    if verb == "clean" and ({"f"} & letters or "--force" in longs):
        return "git clean deletes untracked work irreversibly. Confirm with the user, or list it first with -n."
    # `-n` is --no-verify for commit and --dry-run for push. Only one is a bypass.
    if verb == "commit" and ({"n"} & letters or "--no-verify" in longs):
        return "--no-verify bypasses pre-commit safety checks. Fix the underlying failure instead of bypassing."
    if verb == "push" and "--no-verify" in longs:
        return "--no-verify bypasses pre-push safety checks. Fix the underlying failure instead of bypassing."
    return None


SSH_VALUED = set("-b -c -D -E -e -F -I -i -J -L -l -m -O -o -p -Q -R -S -W -w".split())
SERVICE_VERBS = {"restart", "stop", "start", "reload", "enable", "disable", "daemon-reload"}
PACKAGE_VERBS = {"install", "remove", "purge", "upgrade", "dist-upgrade", "autoremove",
                 "erase", "uninstall", "add"}
PACKAGE_TOOLS = {"apt", "apt-get", "yum", "dnf", "apk", "zypper", "pip", "pip3",
                 "npm", "pnpm", "yarn"}


def mutating(command):
    """True when the command changes the state of the host that runs it."""
    words = lead(command.words)
    if not words:
        return False
    name, rest = base(words[0]), words[1:]
    letters, _, _ = parts(rest)
    if name == "systemctl" and SERVICE_VERBS & set(rest):
        return True
    if name == "postsuper" or (name == "postqueue" and {"f", "d"} & letters):
        return True
    if name in PACKAGE_TOOLS and PACKAGE_VERBS & set(rest):
        return True
    if name == "crontab" and {"e", "r"} & letters:
        return True
    if name == "tee" or name in ("kill", "killall", "pkill"):
        return True
    if name == "sed" and "i" in letters:
        return True
    if name == "rm" and {"r", "R", "f"} & letters:
        return True
    return any(target.startswith("/etc/") for target in command.targets)


def rule_ssh(command, project=""):
    words = lead(command.words)
    if not words or base(words[0]) != "ssh":
        return None
    index = 1
    while index < len(words) and words[index].startswith("-"):
        index += 2 if words[index] in SSH_VALUED else 1
    remote = " ".join(words[index + 1:])
    if remote and any(mutating(nested) for nested in normalize(remote, depth=1)):
        return ("Production mutation via SSH is forbidden from local sessions. Ship the "
                "change through the repo and the approved deploy path; production access "
                "is read-only here.")
    return None


SQL_CLIENTS = {"psql", "mysql", "mariadb"}
DROP = re.compile(r"\bDROP\s+(TABLE|DATABASE|SCHEMA|INDEX)\b", re.I)
TRUNCATE = re.compile(r"\bTRUNCATE\s+(TABLE\s+)?\S", re.I)
DELETE = re.compile(r"\bDELETE\s+FROM\s+\S", re.I)
UPDATE = re.compile(r"\bUPDATE\s+\S+\s+SET\b", re.I)
WHERE = re.compile(r"\bWHERE\b", re.I)


def rule_sql(command, project=""):
    words = lead(command.words)
    if not words or base(words[0]) not in SQL_CLIENTS:
        return None
    # Per statement, so a WHERE on one cannot vouch for the next.
    for word in words[1:]:
        for statement in word.split(";"):
            if DROP.search(statement) or TRUNCATE.search(statement):
                return ("Destructive DDL detected. Confirm with the user and route the "
                        "change through migrations.")
            if (DELETE.search(statement) or UPDATE.search(statement)) and not WHERE.search(statement):
                return ("Unrestricted DELETE/UPDATE (no WHERE clause) detected. Confirm "
                        "with the user before running.")
    return None


def rule_cloud(command, project=""):
    words = lead(command.words)
    if not words:
        return None
    name = base(words[0])
    _, longs, verbs = parts(words[1:])
    if name in ("terraform", "tofu"):
        if "destroy" in verbs or ("apply" in verbs and "-destroy" in words):
            return ("terraform destroy tears down live infrastructure. Confirm with the "
                    "user and run it from the approved deploy path.")
    if name == "aws" and verbs[:1] == ["s3"]:
        if verbs[1:2] == ["rm"] and "--recursive" in longs:
            return "Recursive delete on object storage is irreversible. Confirm with the user."
        if verbs[1:2] == ["rb"] and "--force" in longs:
            return "Removing a bucket and its contents is irreversible. Confirm with the user."
    if name == "kubectl" and "delete" in verbs:
        target = verbs[verbs.index("delete") + 1:verbs.index("delete") + 2]
        if target and target[0] in ("namespace", "namespaces", "ns"):
            return "Deleting a namespace removes every workload in it. Confirm with the user."
        if "--all" in longs:
            return "Deleting every resource of a kind is irreversible. Confirm with the user."
    return None


RULES = (rule_rm, rule_git, rule_ssh, rule_sql, rule_cloud)


def verdict(text, project=""):
    """The reason to block, or None."""
    for command in normalize(text):
        for rule in RULES:
            reason = rule(command, project)
            if reason:
                return reason
    return None


def enabled(repo):
    """The toggle, read the way config.py reads every other one."""
    try:
        with open(os.path.join(repo, ".agents", "config.json"), encoding="utf-8") as config:
            settings = json.load(config)
    except (OSError, ValueError):
        return True
    node = settings
    for name in ("hooks", "guard_destructive", "enabled"):
        if not isinstance(node, dict) or name not in node:
            return True
        node = node[name]
    return node is not False


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    repo = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.dirname(here)))
    if not enabled(repo):
        return 0
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        # A policy that cannot read its input must not block the action.
        return 0
    command = payload.get("command")
    if not isinstance(command, str) or not command.strip():
        return 0
    project = payload.get("project_dir")
    reason = verdict(command, project if isinstance(project, str) else repo)
    if not reason:
        return 0
    print(reason, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())

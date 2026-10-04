#!/usr/bin/env python3
"""Decide whether a shell command is destructive or the user's alone to run,
and say why.

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

import importlib.util
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
# `-c` alone or in a cluster (`-lc`, `-ec`): the shell runs its next word.
SHELL_BODY_FLAG = re.compile(r"-[A-Za-z]*c[A-Za-z]*")
# Shell options whose value is the next word (`-o pipefail`).
SHELL_VALUED = {"-o", "+o", "-O", "+O"}
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
    return [segment for segment, _ in split_operators(text) if segment]


def split_operators(text):
    """Each segment with the operator run that ends it (`&`, `&&`, `;`, `|`, ...).

    An `&` inside a redirection — `2>&1`, `>&2`, `<&3`, `&>log` — belongs to
    the word, not to the operators, so a bare trailing `&` stays readable as
    the background operator it is.
    """
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
        elif char == "&" and (
            (current and current[-1] in "<>") or text[index + 1:index + 2] == ">"
        ):
            current.append(char)
            index += 1
        elif char in OPERATORS:
            start = index
            while index < len(text) and text[index] in OPERATORS:
                index += 1
            found.append(("".join(current).strip(), text[start:index]))
            current = []
        else:
            current.append(char)
            index += 1
    found.append(("".join(current).strip(), ""))
    return found


def cut_redirects(words):
    """Separate redirection targets from the words that name the command.

    Only an output redirection yields a target: `> file` and `2> file` write to
    the host, while `< file` and `<<< word` read and change nothing.
    """
    kept, targets, index = [], [], 0
    while index < len(words):
        word = words[index]
        if word.startswith("&>"):
            width = 2
        elif word and word[0] in "<>":
            width = 1
        elif len(word) > 1 and word[0].isdigit() and word[1] in "<>":
            width = 2
        else:
            kept.append(word)
            index += 1
            continue
        writes = word[width - 1] == ">"
        target = word[width:].lstrip("<>&")
        if not target and index + 1 < len(words):
            index += 1
            target = words[index]
        if target and writes:
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
        if depth < 2 and run and base(run[0]) in SHELLS:
            payload = shell_body(run[1:])
            if payload is not None:
                commands.extend(normalize(payload, depth + 1))
    return commands


def shell_body(args):
    """The command string a shell's `-c` runs, or None when it runs none."""
    index = 0
    while index < len(args) and args[index][:1] in "-+" and args[index] not in ("-", "--"):
        if SHELL_BODY_FLAG.fullmatch(args[index]):
            return args[index + 1] if index + 1 < len(args) else None
        index += 2 if args[index] in SHELL_VALUED else 1
    return None


# Options of the package runners (`uv run`, `uvx`, `npx`, `bunx`, `pnpx`) that
# take a separate value, which names a package, index or file and never the
# command the runner starts. Read from `uv run --help` and `uvx --help`
# (uv 0.12) and npm's `npx --package`/`--call`/`--workspace`.
RUNNER_VALUED = {
    "--extra", "--no-extra", "--group", "--no-group", "--only-group",
    "--no-editable-package", "--env-file", "-w", "--with", "--with-editable",
    "--with-requirements", "--package", "--python-platform", "--index",
    "--default-index", "-i", "--index-url", "--extra-index-url", "-f",
    "--find-links", "--index-strategy", "--keyring-provider", "-P",
    "--upgrade-package", "--upgrade-group", "--resolution", "--prerelease",
    "--prerelease-package", "--fork-strategy", "--exclude-newer",
    "--exclude-newer-package", "--no-sources-package", "--reinstall-package",
    "--link-mode", "-C", "--config-setting", "--config-settings-package",
    "--no-build-isolation-package", "--no-build-package", "--no-binary-package",
    "--cache-dir", "--refresh-package", "-p", "--python", "--color",
    "--allow-insecure-host", "--directory", "--project", "--config-file",
    "--from", "-c", "--constraints", "-b", "--build-constraints", "--overrides",
    "--torch-backend", "--call", "--workspace",
}


def base(word):
    return os.path.basename(word)


# Commands that run the rest of the line, each with the options it reads a
# separate value for. `timeout` also takes its duration before the command.
WRAPPERS = {
    "sudo": {"-u", "-g", "-p", "-C", "-D", "-r", "-t", "-U", "-T", "-R"},
    "env": {"-u", "--unset", "-C", "--chdir", "-S", "--split-string", "-P", "-L", "-U"},
    "command": set(),
    "exec": {"-a"},
    "nohup": set(),
    "time": set(),
    "nice": {"-n", "--adjustment"},
    "caffeinate": {"-t", "-w"},
    "timeout": {"-s", "--signal", "-k", "--kill-after"},
}


def lead(words):
    """The command words, past any environment prefix or wrapper."""
    index = 0
    while index < len(words):
        name = base(words[index])
        if ASSIGNMENT.match(words[index]):
            index += 1
            continue
        if name == "uv" and words[index + 1:index + 2] == ["run"]:
            valued, index = RUNNER_VALUED, index + 2
        elif name in WRAPPERS:
            valued, index = WRAPPERS[name], index + 1
        else:
            break
        while index < len(words) and words[index].startswith("-") and words[index] != "-":
            # `command -v` looks a name up and runs nothing.
            if name == "command" and words[index] in ("-v", "-V"):
                return []
            index += 2 if words[index] in valued else 1
        if name == "timeout":
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
CONTAINER_TOOLS = {"docker", "docker-compose", "podman", "nerdctl"}
CONTAINER_VERBS = {"prune", "rm", "rmi", "down", "stop", "restart", "kill"}
FIND_EXEC = {"-exec", "-execdir", "-ok", "-okdir"}
# The only device paths that discard or echo. Every other entry under /dev is
# storage or hardware, and a redirect onto it is the worst write there is.
DEVICE_SINKS = ("/dev/null", "/dev/zero", "/dev/stdout", "/dev/stderr", "/dev/tty", "/dev/fd/")


def persistent(path):
    """True when a path on the remote host outlives the command.

    Everything on that host is production, so a relative path counts too: it is
    the remote home. A scratch root, a device sink, and a bare descriptor
    number (`2>&1`) do not.
    """
    if path.isdigit():
        return False
    if path.startswith("/"):
        if path.startswith(DEVICE_SINKS):
            return False
        return not any(under(path, root) for root in SCRATCH)
    return True


def delegated(words):
    """The commands `find -exec` hands off, or `xargs` runs, as Commands.

    Both re-enter `normalize`, so a delete hidden in `sh -c '...'` is read too.
    xargs's own flags take values (`-I {}`), so every suffix of its words is
    tried as the command start; a suffix that begins with a flag value names
    no command and decides nothing.
    """
    found = []
    name = base(words[0])
    if name == "find":
        index = 1
        while index < len(words):
            if words[index] in FIND_EXEC:
                end = index + 1
                while end < len(words) and words[end] not in (";", "+"):
                    end += 1
                found.extend(normalize(" ".join(shlex.quote(word) for word in words[index + 1:end]), depth=1))
                index = end
            index += 1
    elif name == "xargs":
        for start in range(1, len(words)):
            found.extend(normalize(" ".join(shlex.quote(word) for word in words[start:]), depth=1))
    return found


def mutating(command):
    """True when the command changes the state of the host that runs it.

    Deletion counts in every spelling, not only `rm -rf`: `find -delete`, a
    delete handed to `-exec` or `xargs`, a container prune or teardown, a
    journal vacuum, `truncate`, and a redirect that empties a file. A move or
    copy counts when it lands outside scratch.
    """
    words = lead(command.words)
    if not words:
        return False
    name, rest = base(words[0]), words[1:]
    letters, longs, operands = parts(rest)
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
    if name in ("rm", "truncate"):
        return True
    if name == "mv" and any(persistent(operand) for operand in operands):
        return True
    if name == "cp" and operands and persistent(operands[-1]):
        return True
    if name == "find" and "-delete" in rest:
        return True
    if name in ("find", "xargs") and any(mutating(nested) for nested in delegated(words)):
        return True
    if name in CONTAINER_TOOLS and CONTAINER_VERBS & set(operands):
        return True
    if name == "journalctl" and any(flag.startswith("--vacuum") for flag in longs):
        return True
    return any(persistent(target) for target in command.targets)


def rule_ssh(command, project=""):
    words = lead(command.words)
    if not words or base(words[0]) != "ssh":
        return None
    index = 1
    while index < len(words) and words[index].startswith("-"):
        index += 2 if words[index] in SSH_VALUED else 1
    remote = " ".join(words[index + 1:])
    # Everything on the far host is production: a command that merely changes
    # state there is denied, and so is anything the local rules would deny,
    # with no project carve-out because no remote path is this working tree.
    for nested in normalize(remote, depth=1):
        if mutating(nested) or any(rule(nested, "") for rule in RULES):
            return ("Production mutation via SSH is forbidden from local sessions. Ship the "
                    "change through the repo and the approved deploy path; production access "
                    "is read-only here.")
    return None


REMOTE_PATH = re.compile(r"^(?:[A-Za-z0-9._-]+@)?[A-Za-z0-9._-]+:")


def remote(operand):
    """True when a copy operand names a host: `host:path`, `user@host:path`, or a URL."""
    return "://" in operand or bool(REMOTE_PATH.match(operand))


def rule_remote_copy(command, project=""):
    words = lead(command.words)
    if not words or base(words[0]) not in ("rsync", "scp"):
        return None
    _, _, operands = parts(words[1:])
    if len(operands) >= 2 and remote(operands[-1]):
        return ("Copying onto a remote host writes to production. Ship the change "
                "through the repo and the approved deploy path.")
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


SYNC_SCRIPT = "browser-sync.py"
# Commands that read, list, or version a file and never run it. `git` covers
# `git add` and a commit message that names the script.
NON_RUNNERS = {"cat", "less", "more", "head", "tail", "grep", "egrep", "rg", "wc",
               "ls", "stat", "file", "diff", "cmp", "echo", "printf", "git"}


def synthetic_source(value):
    """True when a --source value resolves under a scratch root."""
    tmpdir = os.environ.get("TMPDIR")
    if tmpdir:
        for token in ("${TMPDIR}", "$TMPDIR"):
            if value.startswith(token + "/"):
                value = tmpdir.rstrip("/") + value[len(token):]
    if not value.startswith("/"):
        return False
    # macOS links /tmp and /var into /private, so compare resolved to resolved.
    resolved = os.path.realpath(value)
    return any(under(resolved, root) for root in {os.path.realpath(root) for root in SCRATCH})


def sync_runs(words, depth=0):
    """Every word list that runs browser-sync.py.

    Any word naming the script counts, wherever it sits: a wrapper such as
    `timeout`, `nice`, `env`, `uv run`, or `xargs` does not hide it. A shell's
    `-c` body is read as commands of its own. Only a leading reader such as
    `cat` or `git` makes the mention harmless."""
    first = lead(words)
    if first and (base(first[0]) in NON_RUNNERS or (base(first[0]) == "sed" and "-n" in first)):
        return []
    runs, shell = [], False
    for index, word in enumerate(words):
        body = shell and index and SHELL_BODY_FLAG.fullmatch(words[index - 1])
        if body and depth < 3:
            for inner in normalize(word):
                runs += sync_runs(inner.words, depth + 1)
        elif base(word) == SYNC_SCRIPT:
            runs.append(words)
        shell = shell or base(word) in SHELLS
    return runs


def rule_browser_sync(command, project=""):
    """browser-sync.py reads the user's Chrome cookie store. An agent may run it
    only against a synthetic profile it built under a scratch root. This stops
    an accidental run, not a deliberately disguised one."""
    runs = sync_runs(command.words)
    if not runs:
        return None
    def sources(words):
        found = [word.partition("=")[2] for word in words if word.startswith("--source=")]
        return found + [words[index + 1] for index, word in enumerate(words[:-1]) if word == "--source"]
    if all(sources(words) and all(synthetic_source(value) for value in sources(words)) for words in runs):
        return None
    return ("browser-sync.py copies cookies out of the user's own Chrome profile, so "
            "only the user runs it. Ask the user to run it themselves with the ! "
            "prefix: ! python3 .agents/browser-sync.py. An agent may run it only "
            "with --source pointing at a synthetic profile under a temp directory.")


RULES = (rule_rm, rule_git, rule_ssh, rule_remote_copy, rule_sql, rule_cloud,
         rule_browser_sync)


def verdict(text, project="", rules=RULES):
    """The reason to block, or None."""
    for command in normalize(text):
        for rule in rules:
            reason = rule(command, project)
            if reason:
                return reason
    return None


def load_config():
    """config.py, imported by path: it owns the policy.json/config.json layering."""
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("colloid_config", os.path.join(here, "config.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def settings(repo):
    return load_config().load(os.path.join(repo, ".agents", "config.json"))


def enabled(repo):
    """The toggle, read the way config.py reads every other one."""
    return load_config().read(settings(repo), "hooks.guard_destructive.enabled", True)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    # --force asks for the verdict whatever the toggle says. The toggle governs
    # the PreToolUse hook, where a denial the operator disagrees with costs them
    # a tool call; a caller that runs a command with no hook in front of it —
    # the workloop controller's --verify — has no such escape and must not lose
    # the floor because a hook was switched off.
    argv = [arg for arg in sys.argv[1:] if arg != "--force"]
    force = len(argv) != len(sys.argv) - 1
    repo = argv[0] if argv else os.path.dirname(os.path.dirname(os.path.dirname(here)))
    # The toggle switches off the destructive rules only. Running browser-sync
    # is the user's consent to share their cookies, which no operator setting
    # gives on the user's behalf.
    rules = RULES if force or enabled(repo) else (rule_browser_sync,)
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        # A policy that cannot read its input must not block the action.
        return 0
    command = payload.get("command")
    if not isinstance(command, str) or not command.strip():
        return 0
    project = payload.get("project_dir")
    reason = verdict(command, project if isinstance(project, str) else repo, rules)
    if not reason:
        return 0
    print(reason, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())

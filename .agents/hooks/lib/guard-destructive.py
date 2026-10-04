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
# Words that open or close a compound command; the command they guard follows
# in the same segment. guard-publish and teardown-gate strip the same set.
CONTROL_KEYWORDS = {"if", "then", "else", "elif", "fi", "do", "done", "while", "until",
                    "time", "!", "{", "}"}
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


# A word made only of redirection characters, with an optional descriptor
# number in front (`2>`, `>>`, `&>`, `<<<`): the operator itself, not a word it
# is attached to.
REDIRECT_WORD = re.compile(r"[0-9]*[<>&|-]*")


def separate_redirects(segment):
    """The segment with a space before every unquoted redirection that is glued
    to a word, so `echo hi>/etc/motd` tokenizes as `echo hi >/etc/motd`.

    A descriptor number (`2>&1`) stays with its operator, as the shell reads it:
    only an all-digit word in front is a descriptor."""
    out, quote, start, index = [], None, 0, 0
    while index < len(segment):
        char = segment[index]
        if quote:
            out.append(char)
            if char == "\\" and quote == '"' and index + 1 < len(segment):
                out.append(segment[index + 1])
                index += 2
                continue
            if char == quote:
                quote = None
        elif char in "'\"":
            quote = char
            out.append(char)
        elif char == "\\" and index + 1 < len(segment):
            out.extend((char, segment[index + 1]))
            index += 2
            continue
        elif char.isspace():
            out.append(char)
            start = len(out)
        else:
            if char in "<>":
                word = "".join(out[start:])
                if not REDIRECT_WORD.fullmatch(word):
                    # `cmd&>log`: the `&` opens the redirect.
                    cut = len(out) - 1 if word.endswith("&") else len(out)
                    out.insert(cut, " ")
                    start = cut + 1
            out.append(char)
        index += 1
    return "".join(out)


def tokens(segment):
    """(words, output targets) of one segment; raises ValueError when it does not
    tokenize."""
    return cut_redirects(shlex.split(separate_redirects(segment), comments=True))


def normalize(text, depth=0):
    """Every command the text runs, as tokens with one quote layer stripped."""
    commands = []
    for segment in segments(strip_heredocs(text)):
        try:
            words, targets = tokens(segment)
        except ValueError:
            continue
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
            # `env -S '<words>'` splits its value into the command it runs.
            split = env_split(words, index) if name == "env" else None
            if split is not None:
                return lead(split)
            # `command -v` looks a name up and runs nothing.
            if name == "command" and words[index] in ("-v", "-V"):
                return []
            index += 2 if words[index] in valued else 1
        if name == "timeout":
            index += 1
    return words[index:]


def env_split(words, index):
    """The words `env -S`/`--split-string` at words[index] runs, or None when the
    word is another option. A value that does not tokenize stays one word."""
    word = words[index]
    if word in ("-S", "--split-string"):
        value, rest = (words[index + 1] if index + 1 < len(words) else ""), words[index + 2:]
    elif word.startswith("--split-string="):
        value, rest = word.split("=", 1)[1], words[index + 1:]
    elif word.startswith("-S"):
        value, rest = word[2:], words[index + 1:]
    else:
        return None
    try:
        return shlex.split(value) + rest
    except ValueError:
        return [value] + rest


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


# ssh option letters that take a value, attached (`-p2222`) or as the next word.
SSH_VALUED = set("BbcDEeFIiJLlmOoPpQRSWw")
# Options under which ssh logs in to nothing: print its configuration or its
# version, or talk to a running control master.
SSH_NO_LOGIN = set("GVO")
REMOTE_COMMAND = re.compile(r"\s*remotecommand\b", re.I)
# The only device paths that discard or echo. Every other entry under /dev is
# storage or hardware, and a redirect onto it is the worst write there is.
DEVICE_SINKS = ("/dev/null", "/dev/zero", "/dev/stdout", "/dev/stderr", "/dev/tty", "/dev/fd/")


def persistent(path):
    """True when a redirect onto this path on the remote host outlives the command.

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


def operands_past(args, valued):
    """The operands of args, skipping each flag in `valued` together with its value."""
    found, index = [], 0
    while index < len(args):
        word = args[index]
        if word.startswith("-") and word != "-":
            index += 2 if word in valued else 1
        else:
            found.append(word)
            index += 1
    return found


def always(args, depth):
    return True


def find_reads(args, depth):
    """find reads unless it deletes, writes a list file, or hands off a command
    that is not itself a read."""
    if {"-delete", "-fprint", "-fprint0", "-fprintf", "-fls"} & set(args):
        return False
    index = 0
    while index < len(args):
        if args[index] in ("-exec", "-execdir", "-ok", "-okdir"):
            end = index + 1
            while end < len(args) and args[end] not in (";", "+"):
                end += 1
            if not reads(args[index + 1:end], depth + 1):
                return False
            index = end
        index += 1
    return True


XARGS_VALUED = {"-I", "-L", "-n", "-P", "-s", "-E", "-d", "-a", "--max-args",
                "--max-procs", "--max-lines", "--delimiter", "--arg-file", "--eof"}


def xargs_reads(args, depth):
    index = 0
    while index < len(args) and args[index].startswith("-"):
        index += 2 if args[index] in XARGS_VALUED else 1
    # With no command, xargs runs echo.
    return reads(args[index:], depth + 1) if index < len(args) else True


def sed_writes(script):
    """True when a sed script writes a file or runs a command: the `w`, `W` and
    `e` commands, or an `s` command carrying the `w` or `e` flag."""
    size = len(script)

    def past(at, delimiter):
        while at < size and script[at] != delimiter:
            at += 2 if script[at] == "\\" else 1
        return at + 1

    def address(at):
        if at < size and script[at].isdigit():
            while at < size and (script[at].isdigit() or script[at] == "~"):
                at += 1
        elif at < size and script[at] == "$":
            at += 1
        elif at < size and script[at] == "/":
            at = past(at + 1, "/")
        elif at + 1 < size and script[at] == "\\":
            at = past(at + 2, script[at + 1])
        while at < size and script[at] in "IM":
            at += 1
        return at

    index = 0
    while index < size:
        if script[index] in " \t\n;{}!":
            index += 1
            continue
        index = address(index)
        if index < size and script[index] == ",":
            index += 1
            if index < size and script[index] in "+~":
                index += 1
                while index < size and script[index].isdigit():
                    index += 1
            else:
                index = address(index)
        while index < size and script[index] in " \t!":
            index += 1
        if index >= size:
            break
        command = script[index]
        index += 1
        if command in "wWe":
            return True
        if command in "sy" and index < size:
            delimiter = script[index]
            index = past(past(index + 1, delimiter), delimiter)
            flags = index
            while index < size and (script[index] in "gpiImMew" or script[index].isdigit()):
                index += 1
            if command == "s" and {"w", "e"} & set(script[flags:index]):
                return True
        elif command in "aicrRbtT:":
            # Text, a file name or a label runs to the end of the line; a label
            # also ends at `;`.
            while index < size and script[index] != "\n" and not (command in "btT" and script[index] == ";"):
                index += 1
    return False


def sed_reads(args, depth):
    """sed reads unless it edits in place, loads a script file this guard cannot
    see, or runs a script that writes or executes."""
    scripts, operands, index = [], [], 0
    while index < len(args):
        word = args[index]
        index += 1
        if word.startswith("--"):
            name, attached, value = word.partition("=")
            if name.startswith(("--in-place", "--file")):
                return False
            if name in ("--expression", "--line-length") and not attached:
                value = args[index] if index < len(args) else ""
                index += 1
            if name == "--expression":
                scripts.append(value)
        elif word.startswith("-") and word != "-":
            for at, letter in enumerate(word[1:], 1):
                if letter in "if":
                    return False
                if letter in "el":
                    value = word[at + 1:]
                    if not value:
                        value = args[index] if index < len(args) else ""
                        index += 1
                    if letter == "e":
                        scripts.append(value)
                    break
        else:
            operands.append(word)
    return not any(sed_writes(script) for script in scripts or operands[:1])


# A command run through `system()` or a pipe (`print | "sh"`, `"date" | getline`);
# `||` is logical or. And output a print sends to a file.
AWK_RUNS = re.compile(r"\bsystem\s*\(|(?<!\|)\|(?!\|)")
AWK_REDIRECT = re.compile(r"\bprintf?\b[^;{}]*>")


def awk_reads(args, depth):
    """awk reads unless its program runs a command or writes a file, or comes
    from a file or extension this guard cannot see."""
    program, index = None, 0
    while index < len(args):
        word = args[index]
        index += 1
        if word.startswith("--") and word != "--":
            if word.split("=", 1)[0].startswith(("--file", "--exec", "--include", "--load", "--source")):
                return False
        elif word.startswith("-") and word not in ("-", "--"):
            if word[1] in "fEile":
                return False
            if word[1] in "vF" and len(word) == 2:
                index += 1
        elif program is None:
            program = word
    return program is not None and not AWK_RUNS.search(program) and not AWK_REDIRECT.search(program)


def sort_reads(args, depth):
    letters, longs, _ = parts(args)
    return "o" not in letters and "--output" not in longs


def uniq_reads(args, depth):
    # A second operand is the file uniq writes.
    return len(parts(args)[2]) < 2


SET_CLOCK = re.compile(r"\d{4,12}(\.\d\d)?")


def date_reads(args, depth):
    letters, longs, operands = parts(args)
    return ("s" not in letters and "--set" not in longs
            and not any(SET_CLOCK.fullmatch(operand) for operand in operands))


def hostname_reads(args, depth):
    letters, longs, operands = parts(args)
    return not operands and not {"F", "b"} & letters and not {"--file", "--boot"} & longs


def top_reads(args, depth):
    # Without batch mode top waits for a terminal the remote command lacks.
    return "b" in parts(args)[0]


def nginx_reads(args, depth):
    letters = parts(args)[0]
    return "s" not in letters and bool({"t", "T", "v", "V"} & letters)


JOURNAL_WRITES = ("--vacuum", "--rotate", "--flush", "--sync", "--relinquish-var", "--cursor-file",
                  "--smart-relinquish-var", "--setup-keys", "--update-catalog")


def journalctl_reads(args, depth):
    return not any(flag.startswith(JOURNAL_WRITES) for flag in parts(args)[1])


SYSTEMCTL_VALUED = {"-H", "--host", "-M", "--machine", "-t", "--type", "-p", "--property",
                    "-n", "--lines", "-o", "--output", "--state"}
SYSTEMCTL_READS = {"status", "is-active", "is-enabled", "is-failed", "list-units",
                   "list-unit-files", "list-timers", "list-sockets", "list-dependencies",
                   "show", "cat"}


def systemctl_reads(args, depth):
    verbs = operands_past(args, SYSTEMCTL_VALUED)
    # Bare `systemctl` lists units.
    return not verbs or verbs[0] in SYSTEMCTL_READS


DOCKER_VALUED = {"-H", "--host", "-c", "--context", "--config", "-l", "--log-level",
                 "--tlscacert", "--tlscert", "--tlskey",
                 "-f", "--file", "-p", "--project-name", "--project-directory",
                 "--env-file", "--profile"}
DOCKER_READS = {"ps", "logs", "inspect", "images", "version", "info", "top", "port",
                "diff", "history", "stats", "events"}
DOCKER_GROUP_READS = {
    "system": {"df", "info", "events"},
    "container": {"ls", "list", "ps", "inspect", "logs", "top", "port", "diff", "stats"},
    "image": {"ls", "list", "inspect", "history"},
    "network": {"ls", "list", "inspect"},
    "volume": {"ls", "list", "inspect"},
    "context": {"ls", "list", "inspect", "show"},
    "compose": {"ps", "logs", "config", "images", "top", "ls", "version"},
}


def docker_reads(args, depth):
    verbs = operands_past(args, DOCKER_VALUED)
    if not verbs:
        return False
    if verbs[0] in DOCKER_GROUP_READS:
        return verbs[1:2] != [] and verbs[1] in DOCKER_GROUP_READS[verbs[0]]
    return verbs[0] in DOCKER_READS


def compose_reads(args, depth):
    return docker_reads(["compose"] + args, depth)


KUBECTL_VALUED = {"-n", "--namespace", "--context", "--kubeconfig", "--cluster", "--user",
                  "-s", "--server", "-l", "--selector", "-o", "--output", "-c",
                  "--container", "--tail", "--since"}
KUBECTL_READS = {"get", "describe", "logs", "top", "version", "explain", "api-resources",
                 "api-versions", "cluster-info", "events"}
KUBECTL_GROUP_READS = {
    "config": {"view", "get-contexts", "current-context", "get-clusters"},
    "auth": {"can-i", "whoami"},
    "rollout": {"status", "history"},
}


def kubectl_reads(args, depth):
    verbs = operands_past(args, KUBECTL_VALUED)
    if not verbs:
        return False
    if verbs[0] in KUBECTL_GROUP_READS:
        return verbs[1:2] != [] and verbs[1] in KUBECTL_GROUP_READS[verbs[0]]
    return verbs[0] in KUBECTL_READS


GIT_READS = {"log", "status", "diff", "show", "rev-parse", "blame", "ls-files", "ls-tree",
             "cat-file", "describe", "shortlog", "grep"}
# Options under which a git read writes a file or runs a program.
GIT_RUNS = ("--output", "--open-files-in-pager", "--ext-diff", "-O")
BRANCH_VALUED = {"--contains", "--no-contains", "--merged", "--no-merged", "--points-at",
                 "--sort", "--format"}
BRANCH_WRITES = {"--delete", "--move", "--copy", "--force", "--track", "--no-track",
                 "--set-upstream-to", "--unset-upstream", "--edit-description", "--create-reflog"}
TAG_WRITES = {"--delete", "--annotate", "--sign", "--force", "--message", "--file", "--edit",
              "--local-user"}


def git_reads(args, depth):
    words = ["git"] + args
    index = 1
    # Global `-c`, `--config-env` and `--exec-path` choose the programs git runs.
    while index < len(words) and words[index].startswith("-"):
        if words[index].startswith(("-c", "--config-env", "--exec-path")):
            return False
        index += 2 if words[index] in GIT_VALUED else 1
    verb, rest = git_verb(words)
    if any(word.split("=", 1)[0].startswith(GIT_RUNS) for word in rest):
        return False
    letters, longs, operands = parts(rest)
    if verb == "branch":
        if set("dDmMcCfut") & letters or BRANCH_WRITES & longs:
            return False
        return not operands_past(rest, BRANCH_VALUED) or "l" in letters or "--list" in longs
    if verb == "remote":
        return rest in ([], ["-v"], ["--verbose"]) or rest[:1] == ["get-url"]
    if verb == "tag":
        if set("dasfmFeu") & letters or TAG_WRITES & longs:
            return False
        return not rest or "l" in letters or "--list" in longs
    return verb in GIT_READS


def ss_reads(args, depth):
    letters, longs, _ = parts(args)
    return "K" not in letters and "--kill" not in longs


def crontab_reads(args, depth):
    letters = parts(args)[0]
    return "l" in letters and letters <= {"l", "u"} and not operands_past(args, {"-u"})


def dmesg_reads(args, depth):
    letters, longs, _ = parts(args)
    return not set("cCnDE") & letters and not any(
        flag.startswith(("--clear", "--read-clear", "--console")) for flag in longs)


IP_VALUED = {"-n", "-netns", "-f", "-family", "-rc", "-rcvbuf", "-l", "-loops"}
IP_OBJECTS = {"a", "addr", "address", "l", "link", "r", "ro", "route", "n", "neigh",
              "neighbor", "neighbour", "ru", "rule", "m", "maddr", "maddress"}


def ip_reads(args, depth):
    verbs = operands_past(args, IP_VALUED)
    if not verbs or verbs[0] not in IP_OBJECTS:
        return False
    # ip accepts any prefix of a verb: `ip a s` is `ip address show`.
    verb = verbs[1] if len(verbs) > 1 else "show"
    return verb in ("ls", "lst", "get") or "show".startswith(verb) or "list".startswith(verb)


CURL_WRITE_LETTERS = set("XdTFoOKcD")
CURL_WRITES = ("--request", "--data", "--upload-file", "--form", "--output", "--remote-name",
               "--config", "--json", "--cookie-jar", "--dump-header", "--trace", "--libcurl",
               "--stderr", "--create-dirs", "--etag-save", "--hsts", "--alt-svc")


def curl_reads(args, depth):
    """A plain fetch: no request method, body, upload, or file written."""
    letters, longs, _ = parts(args)
    return not CURL_WRITE_LETTERS & letters and not any(flag.startswith(CURL_WRITES) for flag in longs)


def pm2_reads(args, depth):
    verbs = [word for word in args if not word.startswith("-")]
    return verbs[:1] in (["logs"], ["list"], ["ls"])


def ssh_parse(words):
    """(option letters, option values, remote command) of an `ssh` invocation,
    or None when the words are not one. ssh joins its remote words with spaces,
    and so does this."""
    words = lead(words)
    if not words or base(words[0]) != "ssh":
        return None
    letters, values, index = set(), [], 1
    while index < len(words) and words[index].startswith("-") and words[index] != "-":
        word = words[index]
        index += 1
        if word == "--":
            break
        for at, letter in enumerate(word[1:], 1):
            letters.add(letter)
            if letter in SSH_VALUED:
                value = word[at + 1:]
                if not value and index < len(words):
                    value = words[index]
                    index += 1
                values.append((letter, value))
                break
    return letters, values, " ".join(words[index + 1:])


def ssh_remote(words):
    """The command an `ssh` invocation runs on the far host, or None when the
    words are not one."""
    parsed = ssh_parse(words)
    return None if parsed is None else parsed[2]


def runs_unseen(letters, values, remote):
    """True when ssh runs commands this guard cannot read: a RemoteCommand
    option, or a login shell, which with no terminal executes its stdin."""
    if any(letter == "o" and REMOTE_COMMAND.match(value) for letter, value in values):
        return True
    return not remote and not letters & SSH_NO_LOGIN


def ssh_reads(args, depth):
    """A hop to another host reads when what it runs there reads."""
    letters, values, far = ssh_parse(["ssh"] + args)
    return not runs_unseen(letters, values, far) and (not far or remote_offender(far, depth + 1) is None)


# The remote tools that only read, each with the test that keeps a given call
# of it a read. Anything absent is denied: the list grows by a reviewed entry,
# never by a loss that taught a new spelling.
REMOTE_READS = {
    **{name: always for name in (
        "ls", "cat", "zcat", "head", "tail", "less", "more", "grep", "egrep", "fgrep",
        "rg", "stat", "df", "du", "free", "uptime", "ps", "uname", "whoami", "id",
        "printenv", "which", "file", "wc", "tr", "cut", "echo", "printf",
        "cd", "pwd", "true", "false", "test", "[", "[[", "read",
        "netstat", "lsof", "readlink", "sha256sum", "md5sum", "tac", "zgrep", "jq")},
    "find": find_reads, "xargs": xargs_reads, "sed": sed_reads, "awk": awk_reads,
    "gawk": awk_reads, "mawk": awk_reads, "sort": sort_reads, "uniq": uniq_reads,
    "date": date_reads, "hostname": hostname_reads, "top": top_reads,
    "nginx": nginx_reads, "journalctl": journalctl_reads, "systemctl": systemctl_reads,
    "docker": docker_reads, "podman": docker_reads, "docker-compose": compose_reads,
    "kubectl": kubectl_reads, "git": git_reads, "ssh": ssh_reads, "ss": ss_reads,
    "crontab": crontab_reads, "dmesg": dmesg_reads, "ip": ip_reads, "curl": curl_reads,
    "pm2": pm2_reads,
}
# Assignments a remote read may carry: locale and time zone change how output
# is printed, while any other variable (`LD_PRELOAD`, `PAGER`, `GIT_EXTERNAL_DIFF`)
# can make a reader run a program.
SAFE_ASSIGNMENT = re.compile(r"(?:LC_[A-Z_]+|LANG|TZ)=")


def reads(words, depth):
    """True when the command words, run on the far host, only read."""
    while words and words[0] in CONTROL_KEYWORDS:
        words = words[1:]
    if words[:1] == ["for"]:
        return True
    command = lead(words)
    prefix = words[:len(words) - len(command)] if words[len(words) - len(command):] == command else words
    if any(ASSIGNMENT.match(word) and not SAFE_ASSIGNMENT.match(word) for word in prefix):
        return False
    if not command:
        # `sudo -s`, `sudo -i` and a bare `sudo` start a shell that reads stdin;
        # otherwise nothing left is an assignment, `env` printing itself, or
        # `command -v`.
        return not any(base(word) in ("sudo", "doas") for word in prefix)
    name, args = base(command[0]), command[1:]
    if name in SHELLS:
        body = shell_body(args)
        return depth < 3 and body is not None and remote_offender(body, depth + 1) is None
    test = REMOTE_READS.get(name)
    return test is not None and test(args, depth)


def remote_offender(text, depth=0):
    """The first clause of a remote command line that is not a read, or None.

    A sequence or pipeline reads only when every clause does. A clause that does
    not tokenize is returned too: the far shell may read it differently.
    """
    for segment in segments(strip_heredocs(text)):
        try:
            words, targets = tokens(segment)
        except ValueError:
            return segment
        if any(persistent(target) for target in targets) or not reads(words, depth):
            return segment
    return None


def rule_ssh(command, project=""):
    parsed = ssh_parse(command.words)
    if parsed is None:
        return None
    letters, values, remote = parsed
    if runs_unseen(letters, values, remote):
        return ("ssh with no remote command, or with a RemoteCommand option, runs commands "
                "this guard cannot read: a tool call has no terminal, so a login shell "
                "executes whatever reaches its stdin. Run one read-only command per call "
                "as `ssh host '<command>'`; for a login or a tunnel, ask the user to run "
                "it with the ! prefix.")
    offender = remote_offender(remote)
    if offender is None:
        return None
    return (f"Remote commands over SSH are limited to known read-only tools, and "
            f"`{offender}` is not one. Ship a change through the repo and the approved "
            "deploy path; for a read the list lacks, ask the user to run it with the ! "
            "prefix, or propose the entry to the user.")


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

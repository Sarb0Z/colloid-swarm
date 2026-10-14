#!/usr/bin/env python3
"""Report where subagent ("cell") time goes in Claude Code session transcripts.

Read-only; writes nothing. Reads every transcript in the window once for its
timestamps (to find store-wide silence) and each selected cell once more in
full. A spec's baseline and its later QA run this same code.

Figures, per cell (`--json`) and in total:

* time: span, idle gaps over 30 minutes by what ended them, active gaps;
* Bash time by kind of program run (test, build, read, git, other), as
  execution: result delay minus store-wide silence and sibling waits;
* the longest commands, by execution;
* Bash calls past 600 s, past their own `timeout`, and timed out; background
  calls in their own bucket, outside the kinds;
* blind waits: commands `wait-gate.py` would refuse that ran, and its refusals;
* shell writes to tracked files against Edit/Write calls;
* composed-test runs inside workloop lanes.

Silence: a window of over 30 minutes in which no transcript of the whole store
holds a record (the Mac asleep, every session idle). It is cut out of every
delay and gap. A call that overlaps an earlier call of its own assistant
message still pending is also cut by that overlap: it waited on the sibling.

Usage: cell-time.py [--store DIR] [--since YYYY-MM-DD] [--until YYYY-MM-DD]
       [--repo PATH]... [--skip GLOB]... [--state PATH] [--json]
"""

import argparse
import bisect
import datetime
import fnmatch
import heapq
import importlib.util
import json
import os
import posixpath
import re
import shlex
import subprocess
import sys

IDLE_S = 1800
LONG_CALL_S = 600
DEFAULT_TIMEOUT_MS = 120000
TOP = 10
KINDS = ("test", "build", "read", "git", "other")
GAPS = ("model", "tool", "lead", "other")
GIT_VARS = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX")
EDIT_TOOLS = {"Edit", "Write", "MultiEdit"}

SKIPPED_PROGRAMS = {"export", "set", "unset", "pushd", "popd", "source", ".", "true",
                    "false", ":", "for", "case", "in", "esac", "[", "[["}
INTERPRETERS = re.compile(r"^(python[0-9.]*|bash|sh|zsh|node)$")
TEST_SCRIPT = re.compile(r"^(test-.+\.sh|test[-_].+\.py)$")
TEST_PROGRAMS = {"pytest", "py.test", "vitest", "jest", "bats"}
BUILD_SUBCOMMANDS = {"install", "i", "ci", "add", "build"}
BUILD_PROGRAMS = {"tsc", "pip", "pip3"}
READ_PROGRAMS = {"rg", "grep", "egrep", "fgrep", "fd", "find", "ls", "cat", "head", "tail",
                 "awk", "wc", "bat", "jq", "tree"}
READ_GIT = {"status", "diff", "log", "show", "ls-files", "rev-parse", "blame", "grep",
            "cat-file", "ls-tree", "describe", "merge-base", "rev-list", "shortlog",
            "name-rev", "for-each-ref", "reflog"}
GIT_VALUED = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
# Options of the package managers and make that take a separate value, beyond
# the runners' (guard-destructive RUNNER_VALUED).
MANAGER_VALUED = {"--filter", "-F", "--prefix", "--cwd", "--dir", "--registry"}
MAKE_VALUED = {"-C", "-f", "-j", "-I", "-o", "-W", "-l", "--directory", "--file", "--jobs"}
RUN_VALUED = {"-e", "--env", "-u", "--user", "-w", "--workdir", "-v", "--volume", "--name",
              "--entrypoint", "-p", "--publish", "-l", "--label", "--env-file", "--network",
              "--cap-add", "--cap-drop", "--index", "-m", "--memory", "--mount", "--platform",
              "--add-host"}
SED_IN_PLACE = re.compile(r"^-[A-Za-z]*i|^--in-place")
PERL_IN_PLACE = re.compile(r"^-[A-Za-z]*i")
SED_SCRIPT_FLAG = re.compile(r"-[A-Za-z]*[ef]|--expression|--file")
PERL_SCRIPT_FLAG = re.compile(r"-[A-Za-z]*[eEf]")
WRITING_INTERPRETERS = re.compile(r"^(python[0-9.]*|node)$")
LITERAL_WRITES = (
    re.compile(r"""\bopen\(\s*(['"])(.+?)\1\s*,\s*(?:mode\s*=\s*)?['"][wax]b?\+?['"]"""),
    re.compile(r"""\bPath\(\s*(['"])(.+?)\1\s*\)\s*\.\s*(?:write_text|write_bytes)\("""),
    re.compile(r"""\b(?:writeFile|writeFileSync|appendFile|appendFileSync)\(\s*(['"`])(.+?)\1"""),
)
DUP_TARGET = re.compile(r"\d+|-")
LANE_HEADER = re.compile(r"WORKLOOP \w+ BRIEF[^\w\n]+([\w.-]+)/([\w.-]+)")
GATE_PREFIX = "PreToolUse:Bash hook error:"
GATE_BLOCK = re.compile(r"Blocked: (?:this sleeps and then reads|sleeping \S+ s holds|`)")
TIMED_OUT_TEXT = "did not complete within its"
FRACTION = re.compile(r"\.(\d+)")
RAW_STAMP = re.compile(rb'"timestamp"\s*:\s*"(\d{4}-\d\d-\d\d)T(\d\d):(\d\d):(\d\d)')
EPOCH_ORDINAL = datetime.date(1970, 1, 1).toordinal()


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ---------------------------------------------------------------- git access

def run_git(args, cwd):
    """(returncode, stdout) of git in cwd with the GIT_* variables cleared."""
    env = {k: v for k, v in os.environ.items() if k not in GIT_VARS}
    done = subprocess.run(["git", "-C", cwd] + args, capture_output=True, text=True, env=env)
    return done.returncode, done.stdout


class GitReader:
    """Repository facts for a working folder, cached; `runner` executes git."""

    def __init__(self, runner):
        self.runner = runner
        self.tops = {}
        self.files = {}
        self.commons = {}

    def common_dir(self, cwd):
        if cwd not in self.commons:
            code, out = self.runner(["rev-parse", "--git-common-dir"], cwd)
            self.commons[cwd] = os.path.realpath(os.path.join(cwd, out.strip())) if code == 0 else None
        return self.commons[cwd]

    def tracked(self, cwd):
        """Real paths of the tracked files of cwd's repository, or None."""
        if not os.path.isdir(cwd):
            return None
        if cwd not in self.tops:
            code, out = self.runner(["rev-parse", "--show-toplevel"], cwd)
            self.tops[cwd] = os.path.realpath(out.strip()) if code == 0 else None
        top = self.tops[cwd]
        if top is None:
            return None
        if top not in self.files:
            code, out = self.runner(["ls-files", "-z"], top)
            if code != 0:
                raise RuntimeError(f"git ls-files failed in {top}")
            self.files[top] = {os.path.join(top, name) for name in out.split("\0") if name}
        return self.files[top]


class Repos:
    """The `--repo` filter: does a working folder belong to one of them."""

    def __init__(self, paths, git):
        self.git = git
        self.mains = [os.path.realpath(p) for p in paths]
        self.commons = []
        for path in self.mains:
            common = git.common_dir(path)
            if common is None:
                raise SystemExit(f"cell-time: --repo {path} is not a git repository")
            self.commons.append(common)
        self.cache = {}

    def verdict(self, cwd):
        """'in', 'out' (another repository), or 'unattributed' (folder gone)."""
        if not self.mains:
            return "in"
        if cwd not in self.cache:
            self.cache[cwd] = self._decide(cwd)
        return self.cache[cwd]

    def _decide(self, cwd):
        real = os.path.realpath(cwd) if cwd else ""
        if any(real == main or real.startswith(main + os.sep) for main in self.mains):
            return "in"
        if not cwd or not os.path.isdir(cwd):
            return "unattributed"
        return "in" if self.git.common_dir(cwd) in self.commons else "out"

    def preference(self, cwd):
        """Sort key for choosing between copies of one transcript: the copy that
        matches --repo, then the copy whose working folder still exists."""
        return (bool(self.mains) and self.verdict(cwd) == "in", bool(cwd) and os.path.isdir(cwd))


# ------------------------------------------------------------ command reading

def first_arg(args):
    return next((a for a in args if not a.startswith("-")), None)


def after_flags(args, valued):
    """args without the leading options and the values of the valued ones."""
    index = 0
    while index < len(args) and args[index].startswith("-") and args[index] != "-":
        index += 2 if args[index] in valued else 1
    return args[index:]


def script_kind(name):
    if not name:
        return "other"
    if "test" in name or "verify" in name:
        return "test"
    return "build" if name in BUILD_SUBCOMMANDS or name.startswith("build") else "other"


def interpreter_kind(args):
    if "-m" in args and args.index("-m") + 1 < len(args):
        return "test" if args[args.index("-m") + 1] in ("pytest", "unittest") else "other"
    script = first_arg(args)
    return "test" if script and TEST_SCRIPT.match(os.path.basename(script)) else "other"


def go_kind(args):
    sub = first_arg(args)
    return "test" if sub == "test" else "build" if sub in ("build", "check") else "other"


def uv_kind(args):
    return "build" if first_arg(args) in ("sync", "pip", "venv", "add", "lock") else "other"


def next_kind(args):
    return "build" if first_arg(args) == "build" else "other"


def deno_kind(args):
    words = [a for a in args if not a.startswith("-")]
    if words[:1] == ["test"]:
        return "test"
    return script_kind(words[1]) if words[:1] == ["task"] and len(words) > 1 else "other"


def playwright_kind(args):
    return "test" if first_arg(args) == "test" else "other"


def gradle_kind(args):
    tasks = [a.rsplit(":", 1)[-1] for a in args if not a.startswith("-")]
    if any(t in ("test", "check") or t.startswith("test") for t in tasks):
        return "test"
    return "build" if any(t in ("build", "assemble", "clean") for t in tasks) else "other"


def maven_kind(args):
    goals = [a for a in args if not a.startswith("-")]
    if any(g in ("test", "verify", "integration-test") for g in goals):
        return "test"
    return "build" if any(g in ("package", "install", "compile", "clean") for g in goals) else "other"


def xcodebuild_kind(args):
    return "test" if any(a in ("test", "test-without-building") for a in args) else "build"


def git_kind(args):
    rest = after_flags(args, GIT_VALUED)
    return "read" if rest and rest[0] in READ_GIT else "git"


def sed_kind(args):
    return "other" if any(SED_IN_PLACE.match(a) for a in args) else "read"


# ---- what a program writes

def edit_operands(args, in_place, script_flag):
    """File operands of an in-place sed or perl: every operand but the script,
    which is the first one unless -e or -f supplied it."""
    if not any(in_place.match(a) for a in args):
        return []
    files, script, skip = [], False, False
    for index, arg in enumerate(args):
        if skip:
            skip = False
        elif script_flag.fullmatch(arg):
            script, skip = True, True
        elif arg.startswith("--expression=") or arg.startswith("--file=") or (arg.startswith("-e") and len(arg) > 2):
            script = True
        elif arg == "-i" and args[index + 1:index + 2] == [""]:
            skip = True  # BSD sed's separate, empty backup suffix
        elif not (arg.startswith("-") and arg != "-"):
            files.append(arg)
    return files if script else files[1:]


def tee_targets(args):
    return [a for a in args if not a.startswith("-")]


def copy_targets(args):
    """Destinations of cp/mv: the last operand or the -t directory, and the file
    each source would become inside it."""
    operands, target, index = [], None, 0
    while index < len(args):
        arg = args[index]
        if arg in ("-t", "--target-directory") and index + 1 < len(args):
            target, index = args[index + 1], index + 2
            continue
        if arg.startswith("--target-directory="):
            target = arg.split("=", 1)[1]
        elif arg == "--":
            operands += args[index + 1:]
            break
        elif not (arg.startswith("-") and arg != "-"):
            operands.append(arg)
        index += 1
    sources, dest = (operands, target) if target is not None else (operands[:-1], operands[-1] if len(operands) > 1 else None)
    if dest is None:
        return []
    return [dest] + [posixpath.join(dest, posixpath.basename(s.rstrip("/"))) for s in sources]


WRITERS = {
    "sed": lambda args: edit_operands(args, SED_IN_PLACE, SED_SCRIPT_FLAG),
    "perl": lambda args: edit_operands(args, PERL_IN_PLACE, PERL_SCRIPT_FLAG),
    "tee": tee_targets, "cp": copy_targets, "mv": copy_targets,
}


def literal_write_paths(text):
    """Paths a Python or Node write call names as a string literal."""
    return [match.group(2) for pattern in LITERAL_WRITES for match in pattern.finditer(text)]


class Shell:
    """Reads commands with the guard-destructive parser: the programs a command
    runs, what each is for, and what it writes."""

    def __init__(self, parser):
        self.parser = parser
        self.unsplit = 0
        self.kinds = {
            "npx": self.runner, "bunx": self.runner, "pnpx": self.runner, "uvx": self.runner,
            "npm": self.manager, "pnpm": self.manager, "bun": self.manager, "yarn": self.manager,
            "docker": self.docker, "docker-compose": lambda args: self.docker(["compose"] + args),
            "make": self.make, "go": go_kind, "cargo": go_kind, "uv": uv_kind, "next": next_kind,
            "deno": deno_kind, "playwright": playwright_kind, "gradle": gradle_kind,
            "gradlew": gradle_kind, "mvn": maven_kind, "mvnw": maven_kind,
            "xcodebuild": xcodebuild_kind, "git": git_kind, "sed": sed_kind,
        }

    # -- reading

    def programs(self, cmd):
        """[(words, redirect targets)] for each program a command runs, `cd` kept."""
        p, found = self.parser, []
        for segment, _ in p.split_operators(p.strip_heredocs(cmd)):
            try:
                words = shlex.split(p.separate_redirects(segment), comments=True)
            except ValueError:
                self.unsplit += 1
                continue
            words, targets = p.cut_redirects(words)
            while words and words[0] in p.CONTROL_KEYWORDS:
                words = words[1:]
            words = p.lead(words)
            if not words:
                if targets:
                    found.append(([], targets))
                continue
            name = os.path.basename(words[0])
            body = p.shell_body(words[1:]) if name in p.SHELLS else None
            if body is not None:
                found += self.programs(body)
            elif name not in SKIPPED_PROGRAMS or targets:
                found.append((words, targets))
        return found

    @staticmethod
    def words(progs):
        """The word lists of the programs that run something, `cd` aside."""
        return [w for w, _ in progs if w and os.path.basename(w[0]) != "cd"]

    def runs(self, progs, wanted):
        """Whether `progs` run the `wanted` word lists consecutively."""
        words = self.words(progs)
        return bool(wanted) and any(words[i:i + len(wanted)] == wanted for i in range(len(words) - len(wanted) + 1))

    # -- kinds

    def kind(self, progs):
        found = {self.kind_of(w) for w in self.words(progs)}
        return next((kind for kind in KINDS if kind in found), "other")

    def kind_of(self, words):
        """The kind of one program invocation (see KINDS)."""
        name, args = os.path.basename(words[0]), words[1:]
        if name in self.kinds:
            return self.kinds[name](args)
        if name in TEST_PROGRAMS or TEST_SCRIPT.match(name):
            return "test"
        if INTERPRETERS.match(name):
            return interpreter_kind(args)
        if name in BUILD_PROGRAMS:
            return "build"
        return "read" if name in READ_PROGRAMS else "other"

    def runner(self, args):
        rest = after_flags(args, self.parser.RUNNER_VALUED)
        return self.kind_of(rest) if rest else "other"

    def manager(self, args):
        rest = after_flags(args, self.parser.RUNNER_VALUED | MANAGER_VALUED)
        if not rest:
            return "build"
        sub, tail = rest[0], rest[1:]
        if sub in ("run", "run-script"):
            return script_kind(first_arg(after_flags(tail, self.parser.RUNNER_VALUED | MANAGER_VALUED)))
        if sub in ("exec", "x", "dlx"):
            return self.runner(tail)
        if sub == "workspace" and tail:
            return self.manager(tail[1:])
        return script_kind(sub)

    def make(self, args):
        target = next((a for a in after_flags(args, MAKE_VALUED) if "=" not in a), None)
        return "test" if target and script_kind(target) == "test" else "build"

    def docker(self, args):
        """build and pull are builds; run and exec are tests when what they run
        is; up and everything else start or inspect a server."""
        valued = self.parser.DOCKER_VALUED
        words = after_flags(args, valued)
        if words[:1] == ["compose"]:
            words = after_flags(words[1:], valued)
        if not words:
            return "other"
        sub, tail = words[0], words[1:]
        if sub in ("build", "pull", "buildx", "bake"):
            return "build"
        if sub in ("run", "exec"):
            command = after_flags(tail, valued | RUN_VALUED)[1:]
            return "test" if command and self.kind_of(command) == "test" else "other"
        return "other"

    # -- writes

    def writes_source(self, progs, cmd, cwd, git):
        """Whether a program of the command writes a file git tracks."""
        tracked = git.tracked(cwd) if cwd else None
        if not tracked:
            return False
        base = os.path.realpath(cwd)
        for words, targets in progs:
            if words and os.path.basename(words[0]) == "cd":
                base = self.changed_dir(base, words[1:])
                continue
            for path in self.write_targets(words, targets, cmd):
                full = os.path.realpath(os.path.join(base, os.path.expanduser(path)))
                if full in (git.tracked(base) or tracked):
                    return True
        return False

    @staticmethod
    def changed_dir(base, args):
        target = first_arg(args)
        if not target or target == "-":
            return base
        new = os.path.realpath(os.path.join(base, os.path.expanduser(target)))
        return new if os.path.isdir(new) else base

    @staticmethod
    def write_targets(words, targets, cmd):
        paths = [t for t in targets if not t.startswith("/dev/") and not DUP_TARGET.fullmatch(t)]
        if not words:
            return paths
        name, args = os.path.basename(words[0]), words[1:]
        if name in WRITERS:
            paths += WRITERS[name](args)
        elif WRITING_INTERPRETERS.match(name):
            paths += literal_write_paths(cmd)
        return paths


def build_shell():
    lib = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hooks", "lib")
    gate = load_module("wait_gate", os.path.join(lib, "wait-gate.py"))
    return Shell(gate.parser), gate


# --------------------------------------------------------------- transcripts

def parse_time(text):
    if not isinstance(text, str):
        return None
    text = FRACTION.sub(lambda m: "." + m.group(1)[:6].ljust(6, "0"), text.replace("Z", "+00:00"))
    try:
        return datetime.datetime.fromisoformat(text)
    except ValueError:
        return None


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and isinstance(b.get("text"), str))
    return ""


def compact(raw, t):
    """One record reduced to what the figures read."""
    message = raw.get("message") if isinstance(raw.get("message"), dict) else {}
    content = message.get("content")
    outcome = raw.get("toolUseResult")
    timed_out = isinstance(outcome, dict) and bool(outcome.get("timedOutAfterMs"))
    rec = {"t": t, "ts": t.timestamp(), "type": raw.get("type"), "cwd": raw.get("cwd"),
           "msg": message.get("id") or raw.get("requestId"), "uses": [], "results": [], "text": None}
    if isinstance(content, str):
        rec["text"] = content
    for block in content if isinstance(content, list) else []:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "tool_use":
            rec["uses"].append((block.get("id"), block.get("name"), block.get("input") or {}))
        elif block.get("type") == "tool_result":
            text = text_of(block.get("content"))
            rec["results"].append((block.get("tool_use_id"), bool(block.get("is_error")), text,
                                   timed_out or TIMED_OUT_TEXT in text))
    if rec["text"] is None and rec["type"] == "user" and not rec["results"]:
        rec["text"] = text_of(content)
    return rec


class Problems:
    def __init__(self):
        self.unreadable_lines = 0
        self.untimed_records = 0
        self.unreadable_files = []

    def file(self, path, error):
        self.unreadable_files.append(f"{path}: {error}")


def read_cell(path, window, problems):
    """(in-window records, the cell's first user message), read in one pass."""
    records, header = [], None
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                try:
                    raw = json.loads(line)
                except json.JSONDecodeError:
                    raw = None
                if not isinstance(raw, dict):
                    problems.unreadable_lines += 1
                    continue
                t = parse_time(raw.get("timestamp"))
                if t is None:
                    problems.untimed_records += 1
                    continue
                rec = compact(raw, t)
                if rec["text"] and (header is None or t < header[0]):
                    header = (t, rec["text"][:3000])
                if window[0] <= t < window[1]:
                    records.append(rec)
    except (OSError, UnicodeDecodeError) as error:
        problems.file(path, error)
        return [], None
    records.sort(key=lambda r: r["t"])
    return records, header[1] if header else ""


def read_meta(path, problems):
    meta_path = path[:-len(".jsonl")] + ".meta.json"
    if not os.path.exists(meta_path):
        return {}
    try:
        with open(meta_path, encoding="utf-8") as handle:
            meta = json.load(handle)
    except (OSError, ValueError) as error:
        problems.file(meta_path, error)
        return {}
    if not isinstance(meta, dict):
        problems.file(meta_path, "not a JSON object")
        return {}
    return meta


def peek_cwd(path):
    """The working folder of a transcript's first record that names one."""
    try:
        with open(path, encoding="utf-8") as handle:
            for _, line in zip(range(200), handle):
                try:
                    raw = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(raw, dict) and isinstance(raw.get("cwd"), str):
                    return raw["cwd"]
    except (OSError, UnicodeDecodeError):
        return None
    return None


def walk_store(store, skip, not_before, problems):
    """(kind, project, session, name, path) of every transcript modified since
    `not_before`: kind 'main' for `<project>/<session>.jsonl`, 'cell' for
    `<project>/<session>/subagents/agent-*.jsonl`. Skipped projects stay unopened."""

    def fresh(path):
        return os.path.getmtime(path) >= not_before

    def names(folder):
        try:
            return sorted(os.listdir(folder))
        except OSError as error:
            problems.file(folder, error)
            return []

    for project in names(store):
        if any(fnmatch.fnmatch(project, glob) for glob in skip):
            continue
        project_dir = os.path.join(store, project)
        for entry in names(project_dir) if os.path.isdir(project_dir) else []:
            path = os.path.join(project_dir, entry)
            if entry.endswith(".jsonl") and os.path.isfile(path):
                if fresh(path):
                    yield "main", project, entry[:-len(".jsonl")], entry, path
                continue
            agents = os.path.join(path, "subagents")
            for name in names(agents) if os.path.isdir(agents) else []:
                cell = os.path.join(agents, name)
                if name.startswith("agent-") and name.endswith(".jsonl") and fresh(cell):
                    yield "cell", project, entry, name, cell


def choose_copies(cells, repos):
    """(cells, duplicates): session relinking copies a session into other project
    folders, so each (session, name) is read once, from the copy whose working
    folder matches --repo or still exists."""
    groups = {}
    for cell in cells:
        groups.setdefault((cell[2], cell[3]), []).append(cell)
    chosen, duplicates = [], 0
    for copies in groups.values():
        duplicates += len(copies) - 1
        chosen.append(copies[0] if len(copies) == 1 else max(copies, key=lambda c: repos.preference(peek_cwd(c[4]))))
    return sorted(chosen), duplicates


# ------------------------------------------------------------------- silence

class Silence:
    """Windows (epoch seconds) in which no transcript of the store holds a record."""

    def __init__(self, windows):
        self.windows = windows
        self.ends = [end for _, end in windows]

    @property
    def total_s(self):
        return sum(end - start for start, end in self.windows)

    def cuts(self, start, end):
        """The parts of [start, end] that lie inside a window."""
        found = []
        for index in range(bisect.bisect_right(self.ends, start), len(self.windows)):
            low, high = self.windows[index]
            if low >= end:
                break
            found.append((max(low, start), min(high, end)))
        return found


def scan_silence(paths, lo, hi, problems):
    """Silence over `paths`, read for their timestamps only."""
    seconds, days = set(), {}
    for path in paths:
        try:
            with open(path, "rb") as handle:
                for line in handle:
                    stamps = RAW_STAMP.findall(line)
                    if not stamps:
                        continue
                    date, hh, mm, ss = stamps[-1]
                    if date not in days:
                        days[date] = (datetime.date.fromisoformat(date.decode()).toordinal() - EPOCH_ORDINAL) * 86400
                    epoch = days[date] + int(hh) * 3600 + int(mm) * 60 + int(ss)
                    if lo <= epoch < hi:
                        seconds.add(epoch)
        except OSError as error:
            problems.file(path, error)
    ordered = sorted(seconds)
    return Silence([(a, b) for a, b in zip(ordered, ordered[1:]) if b - a > IDLE_S])


def union_seconds(cuts):
    total, edge = 0.0, None
    for start, end in sorted(cuts):
        start = start if edge is None else max(start, edge)
        if end > start:
            total += end - start
            edge = end
    return total


# ------------------------------------------------------------------ figures

def empty_figures():
    return {"span_s": 0.0,
            "idle_s": dict.fromkeys(GAPS, 0.0), "active_s": dict.fromkeys(GAPS, 0.0),
            "shell": {k: {"n": 0, "s": 0.0, "delay_s": 0.0} for k in KINDS},
            "background": {"n": 0, "delay_s": 0.0},
            "bash": {"over_600s": 0, "over_timeout": 0, "timed_out": 0},
            "blind": {"ran": 0, "ran_s": 0.0, "refusals": 0},
            "writes": {"shell_source_writes": 0, "edit_calls": 0, "edit_failures": {}}}


def add(dst, src):
    for key, value in src.items():
        if isinstance(value, dict):
            add(dst.setdefault(key, {}), value)
        else:
            dst[key] = dst.get(key, 0) + value


def is_gate_refusal(text):
    text = text.lstrip()
    return text.startswith(GATE_PREFIX) and "wait-gate.sh" in text and bool(GATE_BLOCK.search(text))


class Call:
    """One tool call from its tool_use to its result."""
    __slots__ = ("id", "name", "inp", "t", "ts", "end", "msg", "order", "kind", "blind")

    def __init__(self, use_id, name, inp, rec, order):
        self.id, self.name, self.inp, self.order = use_id, name, inp, order
        self.t, self.ts, self.msg, self.end = rec["t"], rec["ts"], rec["msg"], None
        self.kind, self.blind = "other", False

    @property
    def delay(self):
        return self.end - self.ts

    @property
    def background(self):
        return bool(self.inp.get("run_in_background"))

    @property
    def timeout_s(self):
        value = self.inp.get("timeout")
        return (value if isinstance(value, (int, float)) and value > 0 else DEFAULT_TIMEOUT_MS) / 1000


class Outcome:
    """A tool result as the figures read it."""
    __slots__ = ("is_error", "text", "timed_out")

    def __init__(self, is_error, text, timed_out):
        self.is_error, self.text, self.timed_out = is_error, text, timed_out


class CellAnalysis:
    """The figures of one cell, built by feeding its records in time order."""

    def __init__(self, shell, git, gate, silence, verify):
        self.shell, self.git, self.gate, self.silence, self.verify = shell, git, gate, silence, verify
        self.fig, self.slow, self.composed = empty_figures(), [], 0
        self.pending, self.edits, self.by_message = {}, set(), {}
        self.last_result, self.prev, self.order = None, None, 0

    def feed(self, rec):
        self.forget_orphans(rec)
        if self.prev is not None:
            self.gap(rec)
        for use_id, name, inp in rec["uses"]:
            self.use(rec, use_id, name, inp)
        for use_id, is_error, text, timed_out in rec["results"]:
            self.result(rec, use_id, Outcome(is_error, text, timed_out))
        self.prev = rec

    def finish(self, records):
        for call in list(self.pending.values()):
            self.forget(call)
        if records:
            self.fig["span_s"] = (records[-1]["t"] - records[0]["t"]).total_seconds()
        return self.fig, self.slow

    # -- time

    def forget_orphans(self, rec):
        """A new turn (an assistant record, or a user message) after a result
        means every call issued before that result either returned or never
        will; the latter must not label later gaps as inside a tool call."""
        if self.last_result is None or not (rec["type"] == "assistant" or (rec["text"] and not rec["results"])):
            return
        for call in [c for c in self.pending.values() if c.ts < self.last_result]:
            self.forget(call)

    def forget(self, call):
        del self.pending[call.id]
        if call.blind:
            self.fig["blind"]["ran"] += 1

    def gap(self, rec):
        seconds = rec["ts"] - self.prev["ts"]
        seconds -= union_seconds(self.silence.cuts(self.prev["ts"], rec["ts"]))
        bucket = "idle_s" if seconds > IDLE_S else "active_s"
        self.fig[bucket][self.gap_kind(rec)] += seconds

    def gap_kind(self, rec):
        if self.pending:
            return "tool"
        if rec["type"] == "assistant":
            return "model"
        if rec["type"] == "user":
            return "tool" if rec["results"] else "lead"
        return "other"

    # -- calls

    def use(self, rec, use_id, name, inp):
        call = Call(use_id, name, inp, rec, self.order)
        self.order += 1
        self.pending[use_id] = call
        if call.msg:
            self.by_message.setdefault(call.msg, []).append(call)
        if name in EDIT_TOOLS:
            self.fig["writes"]["edit_calls"] += 1
            self.edits.add(use_id)
        elif name == "Bash" and isinstance(inp.get("command"), str):
            self.read_command(call, inp["command"], rec["cwd"])

    def read_command(self, call, cmd, cwd):
        progs = self.shell.programs(cmd)
        call.kind = self.shell.kind(progs)
        if self.verify and self.shell.runs(progs, self.verify):
            self.composed += 1
        if self.shell.writes_source(progs, cmd, cwd, self.git):
            self.fig["writes"]["shell_source_writes"] += 1
        call.blind = not call.background and bool(self.gate.verdict(cmd, "cell"))

    def result(self, rec, use_id, outcome):
        call = self.pending.pop(use_id, None)
        if call is None:
            return
        call.end = rec["ts"]
        self.last_result = rec["ts"]
        if use_id in self.edits and outcome.is_error:
            key = outcome.text.replace("<tool_use_error>", "").replace("</tool_use_error>", "").strip().split("\n")[0][:100]
            failures = self.fig["writes"]["edit_failures"]
            failures[key] = failures.get(key, 0) + 1
        if call.name == "Bash":
            self.note_bash(call, outcome)

    def execution(self, call):
        """Result delay minus store-wide silence and the waits on earlier calls
        of the same assistant message that were still pending."""
        cuts = self.silence.cuts(call.ts, call.end)
        for other in self.by_message.get(call.msg, ()) if call.msg else ():
            if other.order < call.order and (other.end is None or other.end > call.ts):
                cuts.append((call.ts, min(call.end, other.end if other.end is not None else call.end)))
        return call.delay - union_seconds(cuts)

    def note_bash(self, call, outcome):
        fig, delay = self.fig, call.delay
        if outcome.timed_out:
            fig["bash"]["timed_out"] += 1
        if call.background:
            fig["background"]["n"] += 1
            fig["background"]["delay_s"] += delay
            return
        run = self.execution(call)
        shell = fig["shell"][call.kind]
        shell["n"] += 1
        shell["s"] += run
        shell["delay_s"] += delay
        fig["bash"]["over_600s"] += delay > LONG_CALL_S
        fig["bash"]["over_timeout"] += delay > call.timeout_s
        self.slow.append((run, delay, call.inp.get("command") or ""))
        if outcome.is_error and is_gate_refusal(outcome.text):
            fig["blind"]["refusals"] += 1
        elif call.blind:
            fig["blind"]["ran"] += 1
            fig["blind"]["ran_s"] += run


def analyze(records, header, verify_for, tools, silence):
    """Figures, the cell's slowest commands, and its lane record (or None)."""
    shell, git, gate = tools
    lane = LANE_HEADER.search(header or "")
    verify = verify_for(lane.group(1)) if lane else None
    cell = CellAnalysis(shell, git, gate, silence, verify)
    for rec in records:
        cell.feed(rec)
    fig, slow = cell.finish(records)
    lane_info = None
    if lane:
        lane_info = {"run": lane.group(1), "lane": lane.group(2), "verify_known": verify is not None,
                     "composed_runs": cell.composed if verify else None}
    return fig, slow, lane_info


# -------------------------------------------------------------------- report

def load_state(path, required):
    if not os.path.exists(path):
        if required:
            raise SystemExit(f"cell-time: state file {path} does not exist")
        return {}
    try:
        with open(path, encoding="utf-8") as handle:
            runs = json.load(handle).get("runs", {})
    except (OSError, ValueError, AttributeError) as error:
        raise SystemExit(f"cell-time: cannot read state file {path}: {error}")
    return runs


def attribute(repos, cwd, lead_cwd):
    """Whether a cell belongs to --repo; a cell whose own folder is gone is
    judged by the folder its session's lead worked in."""
    place = repos.verdict(cwd)
    return repos.verdict(lead_cwd()) if place == "unattributed" else place


def collect(args, tools, runs):
    shell, git, gate = tools
    problems, repos = Problems(), Repos(args.repo, git)
    files = list(walk_store(args.store, args.skip, args.not_before, problems))
    seen, unique = set(), []
    for kind, project, session, name, path in files:
        if (session, name) not in seen:
            seen.add((session, name))
            unique.append(path)
    silence = scan_silence(unique, args.lo, args.hi, problems)
    cells, duplicates = choose_copies([f for f in files if f[0] == "cell"], repos)
    verifies = {}

    def verify_for(run):
        if run not in verifies:
            command = runs.get(run, {}).get("verify") if isinstance(runs.get(run), dict) else None
            verifies[run] = shell.words(shell.programs(command)) if isinstance(command, str) else None
        return verifies[run]

    window = (args.since_dt, args.until_dt)
    totals, detail, slow_all, lanes = empty_figures(), [], [], []
    counts = {"out": 0, "unattributed": 0}
    for _, project, session, name, path in cells:
        records, header = read_cell(path, window, problems)
        if not records:
            continue
        cwd = next((r["cwd"] for r in records if r["cwd"]), None)
        main = os.path.join(args.store, project, session + ".jsonl")
        place = attribute(repos, cwd, lambda: peek_cwd(main))
        if place != "in":
            counts[place] += 1
            continue
        meta = read_meta(path, problems)
        fig, slow, lane = analyze(records, header, verify_for, tools, silence)
        label = meta.get("description") or os.path.basename(path)
        slow_all += [(run, delay, label, cmd) for run, delay, cmd in heapq.nlargest(TOP, slow)]
        add(totals, fig)
        if lane:
            lanes.append(dict(lane, cell=label))
        detail.append(dict(fig, id=name[len("agent-"):-len(".jsonl")], project=project, session=session,
                           description=meta.get("description"), agent_type=meta.get("agentType"),
                           model=meta.get("model"), cwd=cwd))
    longest = [{"execution_s": run, "result_delay_s": delay, "cell": label, "command": " ".join(cmd.split())[:120]}
               for run, delay, label, cmd in heapq.nlargest(TOP, slow_all, key=lambda x: x[0])]
    return {"store": args.store, "since": args.since, "until": args.until, "cells": len(detail),
            "excluded_other_repositories": counts["out"], "unattributed": counts["unattributed"],
            "duplicate_transcripts": duplicates, "unreadable_lines": problems.unreadable_lines,
            "untimed_records": problems.untimed_records, "unreadable_files": problems.unreadable_files,
            "unsplit_segments": shell.unsplit,
            "silence": {"windows": [[iso(a), iso(b)] for a, b in silence.windows], "total_s": silence.total_s},
            "totals": totals, "longest_commands": longest, "lanes": lanes, "cells_detail": detail}


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def dur(seconds):
    seconds = int(round(seconds))
    if seconds >= 3600:
        return f"{seconds // 3600}h{seconds % 3600 // 60:02d}m"
    return f"{seconds // 60}m{seconds % 60:02d}s" if seconds >= 60 else f"{seconds}s"


def gap_line(label, parts):
    names = {"model": "before a model response", "tool": "inside a tool call",
             "lead": "awaiting the lead", "other": "other"}
    return f"  {label} {dur(sum(parts.values()))}: " + ", ".join(f"{names[k]} {dur(parts[k])}" for k in GAPS)


def render_header(report):
    out = [f"cell-time: {report['store']}  window {report['since'] or '-'} .. {report['until'] or '-'}",
           "Codex cells are outside this report; days are UTC.",
           f"cells {report['cells']}; other repositories {report['excluded_other_repositories']}; "
           f"unattributed (working folder gone, lead's too) {report['unattributed']}; "
           f"{report['duplicate_transcripts']} duplicate copies skipped; "
           f"{report['unreadable_lines']} unreadable lines; {report['untimed_records']} records without a timestamp; "
           f"{report['unsplit_segments']} shell segments shlex could not split"]
    return out + [f"unreadable file: {item}" for item in report["unreadable_files"]]


def render_shell(report):
    t, silence = report["totals"], report["silence"]
    out = ["", f"TIME  span {dur(t['span_s'])}", gap_line("idle (gaps over 30 min)", t["idle_s"]),
           gap_line("active", t["active_s"]),
           f"  store-wide silence cut from every delay and gap: {len(silence['windows'])} windows over 30 min "
           f"with no record in any transcript, {dur(silence['total_s'])} in all",
           "", "SHELL TIME BY KIND (execution: delay minus store-wide silence and sibling waits)"]
    out += [f"  {k:<6} {t['shell'][k]['n']:>6} calls  execution {dur(t['shell'][k]['s'])}  (delay {dur(t['shell'][k]['delay_s'])})"
            for k in KINDS]
    b, g = t["bash"], t["background"]
    out += [f"  Bash calls past {LONG_CALL_S} s: {b['over_600s']}; past their own timeout: {b['over_timeout']}; "
            f"timed out: {b['timed_out']}",
            f"  background calls (outside the kinds): {g['n']}, result delay {dur(g['delay_s'])}",
            "", f"LONGEST COMMANDS (execution, top {TOP}; result delay in brackets)"]
    out += [f"  {dur(c['execution_s']):>7} [{dur(c['result_delay_s'])}]  [{c['cell'][:40]}]  {c['command']}"
            for c in report["longest_commands"]]
    return out


def render_work(report):
    t = report["totals"]
    b, w = t["blind"], t["writes"]
    out = ["", f"BLIND WAITS  {b['ran']} ran that the gate would refuse ({dur(b['ran_s'])} of execution); "
               f"{b['refusals']} gate refusals in cells"]
    total = w["shell_source_writes"] + w["edit_calls"]
    share = f"{100 * w['shell_source_writes'] / total:.1f}%" if total else "n/a"
    out += [f"SOURCE WRITES  {w['shell_source_writes']} through the shell vs {w['edit_calls']} Edit/Write/MultiEdit "
            f"calls (shell share {share})"]
    out += [f"  edit failure x{n}: {msg}" for msg, n in sorted(w["edit_failures"].items(), key=lambda x: -x[1])]
    lanes = report["lanes"]
    unknown = [lane for lane in lanes if not lane["verify_known"]]
    ran = [lane for lane in lanes if lane["composed_runs"]]
    out += ["", f"LANES  {len(lanes)} lanes; {len(ran)} ran the composed test; verify unknown for {len(unknown)}"]
    return out + [f"  {lane['run']}/{lane['lane']}: composed test x{lane['composed_runs']}" for lane in ran]


def render(report):
    return "\n".join(render_header(report) + render_shell(report) + render_work(report))


def parse_day(text, name):
    try:
        return datetime.datetime.strptime(text, "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        raise SystemExit(f"cell-time: {name} must be YYYY-MM-DD, got {text!r}")


def parse_args(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="Where subagent time goes in session transcripts (read-only).")
    config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    ap.add_argument("--store", default=os.path.join(config, "projects"))
    ap.add_argument("--since")
    ap.add_argument("--until")
    ap.add_argument("--repo", action="append", default=[])
    ap.add_argument("--skip", action="append", default=[])
    ap.add_argument("--state")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    if not os.path.isdir(args.store):
        raise SystemExit(f"cell-time: store {args.store} is not a directory; pass --store DIR")
    args.since_dt = parse_day(args.since, "--since") if args.since else datetime.datetime.min.replace(
        tzinfo=datetime.timezone.utc) + datetime.timedelta(days=1)
    args.not_before = args.since_dt.timestamp() if args.since else 0.0
    args.until_dt = (parse_day(args.until, "--until") + datetime.timedelta(days=1)) if args.until else \
        datetime.datetime.max.replace(tzinfo=datetime.timezone.utc) - datetime.timedelta(days=1)
    args.lo = args.since_dt.timestamp() if args.since else float("-inf")
    args.hi = args.until_dt.timestamp() if args.until else float("inf")
    args.state_required = args.state is not None
    args.state = args.state or os.path.join(os.path.dirname(here), ".workloop-state.json")
    return args


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    shell, gate = build_shell()
    report = collect(args, (shell, GitReader(run_git), gate), load_state(args.state, args.state_required))
    print(json.dumps(report, indent=2) if args.json else render(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())

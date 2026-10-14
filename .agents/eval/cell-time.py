#!/usr/bin/env python3
"""Report where subagent ("cell") time goes in Claude Code session transcripts.

Read-only. Streams each `<store>/<project>/<session>/subagents/agent-*.jsonl`
once and writes nothing. A spec's baseline and its later QA run this same code.

Figures, per cell (`--json`) and in total:

* time: span, idle gaps over 30 minutes by what ended them, active gaps;
* Bash time by kind of program run (test, build, read, git, other);
* the longest commands by result delay (call to result, not execution time);
* blind waits: commands `wait-gate.py` would refuse that ran, and its refusals;
* shell writes to tracked files against Edit/Write calls;
* composed-test runs inside workloop lanes.

Usage: cell-time.py [--store DIR] [--since YYYY-MM-DD] [--until YYYY-MM-DD]
       [--repo PATH]... [--skip GLOB]... [--state PATH] [--json]
"""

import argparse
import datetime
import fnmatch
import heapq
import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys

IDLE_S = 1800
TOP = 10
KINDS = ("test", "build", "read", "git", "other")
GAPS = ("model", "tool", "lead", "other")
GIT_VARS = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX")
EDIT_TOOLS = {"Edit", "Write", "MultiEdit"}

SKIPPED_PROGRAMS = {"cd", "export", "set", "unset", "pushd", "popd", "source", ".", "true",
                    "false", ":", "for", "case", "in", "esac", "[", "[["}
INTERPRETERS = re.compile(r"^(python[0-9.]*|bash|sh|zsh|node)$")
TEST_SCRIPT = re.compile(r"^(test-.+\.sh|test[-_].+\.py)$")
TEST_PROGRAMS = {"pytest", "py.test", "vitest", "jest", "bats"}
PACKAGE_MANAGERS = {"npm", "pnpm", "bun", "yarn"}
BUILD_SUBCOMMANDS = {"install", "i", "ci", "add", "build"}
BUILD_PROGRAMS = {"tsc", "make", "docker", "docker-compose", "pip", "pip3"}
READ_PROGRAMS = {"rg", "grep", "egrep", "fgrep", "fd", "find", "ls", "cat", "head", "tail",
                 "awk", "wc", "bat", "jq", "tree"}
READ_GIT = {"status", "diff", "log", "show", "ls-files", "rev-parse", "blame", "grep",
            "cat-file", "ls-tree", "describe", "merge-base", "rev-list", "shortlog",
            "name-rev", "for-each-ref", "reflog"}
GIT_VALUED = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
RUNNERS = {"npx", "bunx", "pnpx"}
SED_IN_PLACE = re.compile(r"^-[A-Za-z]*i|^--in-place")
PERL_IN_PLACE = re.compile(r"^-[A-Za-z]*i")
PY_WRITE = re.compile(r"\.write_text\(|\bopen\([^)]*,\s*(?:mode\s*=\s*)?['\"][wa]b?\+?['\"]")
PATH_TOKEN = re.compile(r"[^\s'\"()\[\],;=<>|&]+")
LANE_HEADER = re.compile(r"WORKLOOP \w+ BRIEF[^\w\n]+([\w.-]+)/([\w.-]+)")
GATE_REFUSAL = re.compile(r"^Blocked: (?:this sleeps and then reads|sleeping \S+ s holds|`)")
FRACTION = re.compile(r"\.(\d+)")


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
        """Absolute paths of the tracked files of cwd's repository, or None."""
        if not os.path.isdir(cwd):
            return None
        if cwd not in self.tops:
            code, out = self.runner(["rev-parse", "--show-toplevel"], cwd)
            self.tops[cwd] = out.strip() if code == 0 else None
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


# ------------------------------------------------------------ command reading

def programs(cmd, parser):
    """Yield (words, redirect targets) for each program a command runs."""
    code = parser.strip_heredocs(cmd)
    for segment, _ in parser.split_operators(code):
        try:
            words = shlex.split(segment, comments=True)
        except ValueError:
            continue
        words, targets = parser.cut_redirects(words)
        while words and words[0] in parser.CONTROL_KEYWORDS:
            words = words[1:]
        words = parser.lead(words)
        if not words:
            if targets:
                yield [], targets
            continue
        name = os.path.basename(words[0])
        if name in parser.SHELLS:
            body = shell_body(words, parser)
            if body is not None:
                yield from programs(body, parser)
                continue
        if name in SKIPPED_PROGRAMS and not targets:
            continue
        yield words, targets


def shell_body(words, parser):
    for index, word in enumerate(words[1:], 1):
        if parser.SHELL_BODY_FLAG.fullmatch(word) and index + 1 < len(words):
            return words[index + 1]
    return None


def first_arg(args):
    return next((a for a in args if not a.startswith("-")), None)


def script_kind(name):
    if not name:
        return "other"
    if "test" in name or "verify" in name:
        return "test"
    return "build" if name in BUILD_SUBCOMMANDS or name.startswith("build") else "other"


def package_manager_kind(args):
    sub = first_arg(args)
    if sub in ("run", "run-script"):
        rest = args[args.index(sub) + 1:]
        return script_kind(first_arg(rest))
    return script_kind(sub)


def interpreter_kind(args):
    if "-m" in args and args.index("-m") + 1 < len(args):
        return "test" if args[args.index("-m") + 1] in ("pytest", "unittest") else "other"
    script = first_arg(args)
    return "test" if script and TEST_SCRIPT.match(os.path.basename(script)) else "other"


def git_kind(args):
    index = 0
    while index < len(args) and args[index].startswith("-"):
        index += 2 if args[index] in GIT_VALUED else 1
    sub = args[index] if index < len(args) else None
    return "read" if sub in READ_GIT else "git"


def kind_of(words):
    """The kind of one program invocation (see KINDS)."""
    name, args = os.path.basename(words[0]), words[1:]
    if name in RUNNERS and args:
        return kind_of(args)
    if name in TEST_PROGRAMS or TEST_SCRIPT.match(name):
        return "test"
    if name in PACKAGE_MANAGERS:
        return package_manager_kind(args)
    if INTERPRETERS.match(name):
        return interpreter_kind(args)
    if name == "go" or name == "cargo":
        sub = first_arg(args)
        return "test" if sub == "test" else "build" if sub in ("build", "check") else "other"
    if name == "uv":
        return "build" if first_arg(args) in ("sync", "pip", "venv", "add", "lock") else "other"
    if name == "next":
        return "build" if first_arg(args) == "build" else "other"
    if name in BUILD_PROGRAMS:
        return "build"
    if name == "git":
        return git_kind(args)
    if name == "sed":
        return "other" if any(SED_IN_PLACE.match(a) for a in args) else "read"
    return "read" if name in READ_PROGRAMS else "other"


def command_kind(cmd, parser):
    found = {kind_of(words) for words, _ in programs(cmd, parser) if words}
    return next((kind for kind in KINDS if kind in found), "other")


def write_paths(cmd, parser):
    """Words a command may write to: redirect targets, `sed -i`/`perl -pi`/`tee`
    operands, and every token of a command whose Python writes a file."""
    paths, python = [], False
    for words, targets in programs(cmd, parser):
        paths += [t for t in targets if not t.startswith("/dev/")]
        if not words:
            continue
        name, args = os.path.basename(words[0]), words[1:]
        operands = [a for a in args if not a.startswith("-")]
        if (name == "sed" and any(SED_IN_PLACE.match(a) for a in args)) or name == "tee":
            paths += operands
        elif name == "perl" and any(PERL_IN_PLACE.match(a) for a in args):
            paths += operands
        elif name.startswith("python"):
            python = True
    if python and PY_WRITE.search(cmd):
        paths += PATH_TOKEN.findall(cmd)
    return paths


def is_source_write(cmd, cwd, git, parser):
    tracked = git.tracked(cwd) if cwd else None
    if not tracked:
        return False
    base = os.path.realpath(cwd)
    for path in write_paths(cmd, parser):
        if path and os.path.normpath(os.path.join(base, os.path.expanduser(path))) in tracked:
            return True
    return False


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
    rec = {"t": t, "type": raw.get("type"), "cwd": raw.get("cwd"), "uses": [], "results": [], "text": None}
    if isinstance(content, str):
        rec["text"] = content
    for block in content if isinstance(content, list) else []:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "tool_use":
            rec["uses"].append((block.get("id"), block.get("name"), block.get("input") or {}))
        elif block.get("type") == "tool_result":
            rec["results"].append((block.get("tool_use_id"), bool(block.get("is_error")), text_of(block.get("content"))))
    if rec["text"] is None and rec["type"] == "user" and not rec["results"]:
        rec["text"] = text_of(content)
    return rec


class Problems:
    def __init__(self):
        self.unreadable_lines = 0
        self.untimed_records = 0
        self.unreadable_files = []


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
    except OSError as error:
        problems.unreadable_files.append(f"{path}: {error}")
        return [], None
    records.sort(key=lambda r: r["t"])
    return records, header[1] if header else ""


def find_transcripts(store, skip, not_before, duplicates):
    """(project, session, path) of each cell once. Session relinking copies a
    session into other project folders; the first copy found is the one read,
    and `duplicates` counts the rest."""
    seen = set()
    for project in sorted(os.listdir(store)):
        if any(fnmatch.fnmatch(project, glob) for glob in skip):
            continue
        project_dir = os.path.join(store, project)
        if not os.path.isdir(project_dir):
            continue
        for session in sorted(os.listdir(project_dir)):
            agents = os.path.join(project_dir, session, "subagents")
            if not os.path.isdir(agents):
                continue
            for name in sorted(os.listdir(agents)):
                path = os.path.join(agents, name)
                if not (name.startswith("agent-") and name.endswith(".jsonl")):
                    continue
                if (session, name) in seen:
                    duplicates[0] += 1
                    continue
                seen.add((session, name))
                if os.path.getmtime(path) >= not_before:
                    yield project, session, path


def read_meta(path):
    meta_path = path[:-len(".jsonl")] + ".meta.json"
    if not os.path.exists(meta_path):
        return {}
    with open(meta_path, encoding="utf-8") as handle:
        return json.load(handle)


# ------------------------------------------------------------------ figures

def gap_kind(pending, rec):
    if pending:
        return "tool"
    if rec["type"] == "assistant":
        return "model"
    if rec["type"] == "user":
        return "tool" if rec["results"] else "lead"
    return "other"


def empty_figures():
    return {"span_s": 0.0,
            "idle_s": dict.fromkeys(GAPS, 0.0), "active_s": dict.fromkeys(GAPS, 0.0),
            "shell": {k: {"n": 0, "s": 0.0} for k in KINDS},
            "blind": {"ran": 0, "ran_s": 0.0, "refusals": 0},
            "writes": {"shell_source_writes": 0, "edit_calls": 0, "edit_failures": {}}}


def add(dst, src):
    for key, value in src.items():
        if isinstance(value, dict):
            add(dst.setdefault(key, {}), value)
        else:
            dst[key] = dst.get(key, 0) + value


def is_gate_refusal(text):
    return "wait-gate" in text or bool(GATE_REFUSAL.match(text.lstrip()))


def analyze(records, header, verify_for, tools):
    """Figures, the cell's slowest commands, and its lane record (or None)."""
    git, parser, gate = tools
    fig, slow = empty_figures(), []
    lane = LANE_HEADER.search(header or "")
    verify = verify_for(lane.group(1)) if lane else None
    composed = 0
    pending, blind, edits, prev = {}, set(), set(), None
    for rec in records:
        if prev is not None:
            gap = (rec["t"] - prev["t"]).total_seconds()
            bucket = "idle_s" if gap > IDLE_S else "active_s"
            fig[bucket][gap_kind(pending, rec)] += gap
        for use_id, name, inp in rec["uses"]:
            pending[use_id] = (rec["t"], name, inp)
            if name in EDIT_TOOLS:
                fig["writes"]["edit_calls"] += 1
                edits.add(use_id)
            elif name == "Bash" and isinstance(inp.get("command"), str):
                cmd = inp["command"]
                composed += bool(verify) and verify in cmd
                fig["writes"]["shell_source_writes"] += is_source_write(cmd, rec["cwd"], git, parser)
                if not inp.get("run_in_background") and gate.verdict(cmd, "cell"):
                    blind.add(use_id)
        for use_id, is_error, text in rec["results"]:
            started = pending.pop(use_id, None)
            if started is None:
                continue
            if use_id in edits and is_error:
                key = text.replace("<tool_use_error>", "").replace("</tool_use_error>", "").strip().split("\n")[0][:100]
                failures = fig["writes"]["edit_failures"]
                failures[key] = failures.get(key, 0) + 1
            if started[1] == "Bash":
                note_bash(fig, slow, started, rec["t"], is_error, text, use_id in blind, parser)
                blind.discard(use_id)
        prev = rec
    fig["blind"]["ran"] += sum(1 for use_id in blind if use_id in pending)
    if records:
        fig["span_s"] = (records[-1]["t"] - records[0]["t"]).total_seconds()
    lane_info = None
    if lane:
        lane_info = {"run": lane.group(1), "lane": lane.group(2), "verify_known": verify is not None,
                     "composed_runs": composed if verify else None}
    return fig, slow, lane_info


def note_bash(fig, slow, started, ended, is_error, text, blind, parser):
    t0, _, inp = started
    delay = (ended - t0).total_seconds()
    cmd = inp.get("command") or ""
    kind = command_kind(cmd, parser)
    fig["shell"][kind]["n"] += 1
    fig["shell"][kind]["s"] += delay
    slow.append((delay, cmd))
    if is_error and is_gate_refusal(text):
        fig["blind"]["refusals"] += 1
    elif blind:
        fig["blind"]["ran"] += 1
        fig["blind"]["ran_s"] += delay


def first_cwd(records):
    return next((r["cwd"] for r in records if r["cwd"]), None)


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


def collect(args, tools, runs):
    store, git = args.store, tools[0]
    window = (args.since_dt, args.until_dt)
    repos = Repos(args.repo, git)
    problems, totals, cells, slow_all, lanes = Problems(), empty_figures(), [], [], []
    counts = {"other_repositories": 0, "unattributed": 0}
    duplicates = [0]

    def verify_for(run):
        return runs.get(run, {}).get("verify") if isinstance(runs.get(run), dict) else None

    for project, session, path in find_transcripts(store, args.skip, args.not_before, duplicates):
        records, header = read_cell(path, window, problems)
        if not records:
            continue
        cwd = first_cwd(records)
        place = repos.verdict(cwd)
        if place != "in":
            counts["other_repositories" if place == "out" else "unattributed"] += 1
            continue
        meta = read_meta(path)
        fig, slow, lane = analyze(records, header, verify_for, tools)
        label = meta.get("description") or os.path.basename(path)
        slow_all += [(d, label, c) for d, c in heapq.nlargest(TOP, slow)]
        add(totals, fig)
        if lane:
            lanes.append(dict(lane, cell=label))
        cells.append(dict(fig, id=os.path.basename(path)[len("agent-"):-len(".jsonl")], project=project,
                          session=session, description=meta.get("description"),
                          agent_type=meta.get("agentType"), model=meta.get("model"), cwd=cwd))
    longest = [{"result_delay_s": d, "cell": label, "command": " ".join(c.split())[:120]}
               for d, label, c in heapq.nlargest(TOP, slow_all, key=lambda x: x[0])]
    return {"store": store, "since": args.since, "until": args.until, "cells": len(cells),
            "excluded_other_repositories": counts["other_repositories"],
            "unattributed": counts["unattributed"], "duplicate_transcripts": duplicates[0],
            "unreadable_lines": problems.unreadable_lines, "untimed_records": problems.untimed_records,
            "unreadable_files": problems.unreadable_files,
            "totals": totals, "longest_commands": longest, "lanes": lanes, "cells_detail": cells}


def dur(seconds):
    seconds = int(round(seconds))
    if seconds >= 3600:
        return f"{seconds // 3600}h{seconds % 3600 // 60:02d}m"
    return f"{seconds // 60}m{seconds % 60:02d}s" if seconds >= 60 else f"{seconds}s"


def gap_line(label, parts):
    names = {"model": "before a model response", "tool": "inside a tool call",
             "lead": "awaiting the lead", "other": "other"}
    return f"  {label} {dur(sum(parts.values()))}: " + ", ".join(f"{names[k]} {dur(parts[k])}" for k in GAPS)


def render(report):
    t = report["totals"]
    out = [f"cell-time: {report['store']}  window {report['since'] or '-'} .. {report['until'] or '-'}",
           f"cells {report['cells']}; other repositories {report['excluded_other_repositories']}; "
           f"unattributed (working folder gone) {report['unattributed']}; "
           f"{report['duplicate_transcripts']} duplicate copies skipped; "
           f"{report['unreadable_lines']} unreadable lines; {report['untimed_records']} records without a timestamp"]
    out += [f"unreadable file: {item}" for item in report["unreadable_files"]]
    out += ["", f"TIME  span {dur(t['span_s'])}", gap_line("idle (gaps over 30 min)", t["idle_s"]),
            gap_line("active", t["active_s"]), "", "SHELL TIME BY KIND (Bash result delay)"]
    out += [f"  {k:<6} {t['shell'][k]['n']:>6} calls  {dur(t['shell'][k]['s'])}" for k in KINDS]
    out += ["", f"LONGEST COMMANDS (result delay, top {TOP})"]
    out += [f"  {dur(c['result_delay_s']):>7}  [{c['cell'][:40]}]  {c['command']}" for c in report["longest_commands"]]
    b, w = t["blind"], t["writes"]
    out += ["", f"BLIND WAITS  {b['ran']} ran that the gate would refuse ({dur(b['ran_s'])}); "
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
    out += [f"  {lane['run']}/{lane['lane']}: composed test x{lane['composed_runs']}" for lane in ran]
    return "\n".join(out)


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
    args.state_required = args.state is not None
    args.state = args.state or os.path.join(os.path.dirname(here), ".workloop-state.json")
    return args


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    lib = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hooks", "lib")
    gate = load_module("wait_gate", os.path.join(lib, "wait-gate.py"))
    tools = (GitReader(run_git), gate.parser, gate)
    report = collect(args, tools, load_state(args.state, args.state_required))
    print(json.dumps(report, indent=2) if args.json else render(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())

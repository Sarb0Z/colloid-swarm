#!/usr/bin/env python3
"""Tell an agent which systems it can read, and whether they answer.

`policy.json` (tracked, one per repository) declares the systems the product
runs on under a top-level `systems` list. Names and commands only; credential
routes and account snapshots stay in the gitignored `CLAUDE.local.md`:

    {"systems": [{"name": "github",
                  "probe": "gh auth status --hostname github.com",
                  "read": ["gh pr list --limit 20"],
                  "logs": {"ci": "gh run view <run-id> --log-failed"}}]}

`probe` exits 0 when the system is reachable with the operator's own login.
`read` lists read-only commands an agent may run. `logs` (optional) maps an
environment name to its log command. Only `policy.json` is read: a system
list is a repository decision, not one operator's setting.

Every declared command goes through both guards (`hooks/lib/guard_verdict.py`:
the destructive guard and the publish guard, asked as the workloop controller
asks them). A command a guard refuses is never run here, and `check` names it,
so a write declared as a read is caught before anyone runs it. A guard cannot
see through shell expansion, so a declared command is literal: no `$` and no
backtick. `logs` environments are `local`, `staging` and `production`.

Usage:
  access.py check [--repo DIR]
  access.py probe [--name NAME] [--repo DIR]
  access.py list  [--repo DIR]

`probe` runs each probe in the repository root with a 10-second timeout and
keeps only reachable or unreachable, the exit status (or `timeout`) and the
time; probe output is discarded. A full probe writes the `systems` readout
(stale after a day); `--name` probes one system and writes nothing, because
the readout describes the whole table.
"""
import argparse
import json
import os
import re
import signal
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "hooks" / "lib"))
import guard_verdict  # noqa: E402
import readout  # noqa: E402

NAME = re.compile(r"[a-z0-9]+(-[a-z0-9]+)*")
LOG_ENVIRONMENTS = ("local", "staging", "production")
KEYS = {"name", "probe", "read", "logs"}
EXPANSION = re.compile(r"[$`]")
PROBE_TIMEOUT = 10
STALE_AFTER = 86400
NONE_DECLARED = ("no systems declared in .agents/policy.json; add a top-level `systems` list "
                 "(the Systems step of .agents/export/README.md)")


def load_systems(repo):
    """Return (systems or None when the key is absent, schema errors)."""
    path = Path(repo) / ".agents" / "policy.json"
    if not path.is_file():
        return None, []
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return None, [f"{path}: cannot read as JSON ({error})"]
    if not isinstance(document, dict):
        return None, [f"{path}: top level must be an object"]
    if "systems" not in document:
        return None, []
    systems = document["systems"]
    if not isinstance(systems, list):
        return [], ["systems: must be a list"]
    errors, seen = [], set()
    for index, entry in enumerate(systems):
        label = f"systems[{index}]"
        if not isinstance(entry, dict):
            errors.append(f"{label}: must be an object")
            continue
        name = entry.get("name")
        if isinstance(name, str) and NAME.fullmatch(name):
            label = f"system {name}"
            if name in seen:
                errors.append(f"{label}: name declared twice")
            seen.add(name)
        else:
            errors.append(f"{label}: name must match [a-z0-9]+(-[a-z0-9]+)*")
        for key in sorted(set(entry) - KEYS):
            errors.append(f"{label}: unknown key {key!r}")
        if not (isinstance(entry.get("probe"), str) and entry["probe"].strip()):
            errors.append(f"{label}: probe must be a non-empty command string")
        reads = entry.get("read")
        if not (isinstance(reads, list) and all(isinstance(c, str) and c.strip() for c in reads)):
            errors.append(f"{label}: read must be a list of non-empty command strings")
        logs = entry.get("logs", {})
        if not isinstance(logs, dict):
            errors.append(f"{label}: logs must be an object of environment name to command")
        else:
            for env_name, command in logs.items():
                if env_name not in LOG_ENVIRONMENTS:
                    errors.append(f"{label}: log environment {env_name!r} must be one of {', '.join(LOG_ENVIRONMENTS)}")
                if not (isinstance(command, str) and command.strip()):
                    errors.append(f"{label}: log {env_name} must be a non-empty command string")
    if errors:
        return systems, errors
    for entry in systems:
        for role, command in commands(entry):
            if EXPANSION.search(command):
                errors.append(f"`{command}` in system {entry['name']}, {role}: "
                              "declared commands are literal: no shell expansion ($ or backtick)")
    return systems, errors


def commands(system):
    """Every declared command of one system as (role, command)."""
    yield "probe", system["probe"]
    for command in system["read"]:
        yield "read", command
    for env_name, command in system.get("logs", {}).items():
        yield f"log {env_name}", command


def guard_reason(repo, command):
    """"<guard>: <reason>" when a guard refuses `command`, else None."""
    refused = guard_verdict.verdict(command, repo)
    return f"{refused[0]}: {refused[1]}" if refused else None


def refusals(repo, system):
    """(role, command, reason) for each declared command the guard would not pass quietly."""
    found = []
    for role, command in commands(system):
        reason = guard_reason(repo, command)
        if reason:
            found.append((role, command, reason))
    return found


def cmd_check(repo):
    systems, errors = load_systems(repo)
    problems = list(errors)
    if not errors:
        for system in systems or []:
            for role, command, reason in refusals(repo, system):
                problems.append(f"`{command}` in system {system['name']}, {role}: refused by {reason}")
    for problem in problems:
        print(f"FAIL: {problem}", file=sys.stderr)
    if problems:
        return 1
    print(f"systems: {len(systems or [])} declared, every command passes the guards"
          if systems is not None else NONE_DECLARED)
    return 0


def cmd_list(repo):
    systems, errors = load_systems(repo)
    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1
    if systems is None:
        print(NONE_DECLARED)
        return 0
    for system in systems:
        print(f"{system['name']}")
        print(f"  probe: {system['probe']}")
        for command in system["read"]:
            print(f"  read: {command}")
        for env_name, command in system.get("logs", {}).items():
            print(f"  log {env_name}: {command}")
    return 0


def run_probe(repo, command):
    """The probe's exit status, or 'timeout'; its output is discarded."""
    process = subprocess.Popen(command, shell=True, cwd=repo, stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        return process.wait(timeout=PROBE_TIMEOUT)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        return "timeout"


def cmd_probe(repo, name):
    systems, errors = load_systems(repo)
    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1
    if not systems:
        # A readout of systems that are no longer declared would mislead.
        (readout.folder(repo) / "systems.json").unlink(missing_ok=True)
        print(NONE_DECLARED)
        return 0
    if name is not None:
        systems = [s for s in systems if s["name"] == name]
        if not systems:
            print(f"FAIL: no system named {name} in .agents/policy.json", file=sys.stderr)
            return 1
    refused, problems, lines = False, [], []
    for system in systems:
        label = system["name"]
        reason = guard_reason(repo, system["probe"])
        if reason:
            refused = True
            print(f"FAIL: probe `{system['probe']}` in system {label} not run: refused by {reason}",
                  file=sys.stderr)
            lines.append(f"{label}: probe refused by the guards")
            problems.append(f"{label} refused")
            continue
        status = run_probe(repo, system["probe"])
        if status == 0:
            state = "reachable (exit 0)"
        else:
            problems.append(f"{label} unreachable")
            state = f"unreachable ({'timeout' if status == 'timeout' else f'exit {status}'})"
        environments = ", ".join(system.get("logs", {})) or "none"
        lines.append(f"{label}: {state}, {len(system['read'])} reads, logs: {environments}")
    for line in lines:
        print(line)
    if name is None:
        strip = f"systems: {', '.join(problems)}" if problems else ""
        readout.write(repo, "systems", strip=strip, note="\n".join(lines), stale_after=STALE_AFTER)
    return 1 if refused else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("command", choices=["check", "probe", "list"])
    parser.add_argument("--name", help="probe one system only (probe)")
    parser.add_argument("--repo", default=str(HERE.parent), help="repository root (default: this one)")
    args = parser.parse_args()
    repo = Path(args.repo).resolve()
    if args.command == "list":
        return cmd_list(repo)
    try:
        return cmd_check(repo) if args.command == "check" else cmd_probe(repo, args.name)
    except guard_verdict.GuardFailure as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

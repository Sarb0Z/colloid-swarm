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

Every declared command goes through the publish guard
(`hooks/lib/guard-publish.py`) the way a Bash call in default permission mode
does. A command the guard would ask about or deny is never run here, and
`check` names it, so a write declared as a read is caught before anyone runs it.

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
import readout  # noqa: E402

GUARD = HERE / "hooks" / "lib" / "guard-publish.py"
NAME = re.compile(r"[a-z0-9]+(-[a-z0-9]+)*")
ENV_NAME = re.compile(r"[a-z0-9]+(-[a-z0-9]+)*")
KEYS = {"name", "probe", "read", "logs"}
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
                if not ENV_NAME.fullmatch(env_name):
                    errors.append(f"{label}: log environment {env_name!r} must be lower-case words joined by hyphens")
                if not (isinstance(command, str) and command.strip()):
                    errors.append(f"{label}: log {env_name} must be a non-empty command string")
    return systems, errors


def commands(system):
    """Every declared command of one system as (role, command)."""
    yield "probe", system["probe"]
    for command in system["read"]:
        yield "read", command
    for env_name, command in system.get("logs", {}).items():
        yield f"log {env_name}", command


def guard_reason(repo, command):
    """The guard's reason when it would ask about or deny `command`, else None."""
    payload = {"tool_name": "Bash", "tool_input": {"command": command},
               "permission_mode": "default", "cwd": str(repo)}
    result = subprocess.run([sys.executable, str(GUARD), str(repo), "--force"], input=json.dumps(payload),
                            capture_output=True, text=True)
    if result.returncode != 0:
        return f"the publish guard failed (exit {result.returncode}): {result.stderr.strip()}"
    if not result.stdout.strip():
        return None
    try:
        return json.loads(result.stdout)["hookSpecificOutput"]["permissionDecisionReason"]
    except (ValueError, KeyError, TypeError):
        return f"the publish guard answered unreadably: {result.stdout.strip()[:200]}"


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
                problems.append(f"`{command}` in system {system['name']}, {role}: the publish guard asks: {reason}")
    for problem in problems:
        print(f"FAIL: {problem}", file=sys.stderr)
    if problems:
        return 1
    print(f"systems: {len(systems or [])} declared, every command passes the publish guard"
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
    """(exit status or 'timeout', None) with the probe's output discarded."""
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
    if systems is None:
        print(NONE_DECLARED)
        return 0
    if name is not None:
        systems = [s for s in systems if s["name"] == name]
        if not systems:
            print(f"FAIL: no system named {name} in .agents/policy.json", file=sys.stderr)
            return 1
    refused, unreachable, lines = False, [], []
    for system in systems:
        label = system["name"]
        reason = guard_reason(repo, system["probe"])
        if reason:
            refused = True
            print(f"FAIL: probe `{system['probe']}` in system {label} not run: the publish guard asks: {reason}",
                  file=sys.stderr)
            lines.append(f"{label}: probe refused by the publish guard")
            continue
        status = run_probe(repo, system["probe"])
        if status == 0:
            state = "reachable (exit 0)"
        else:
            unreachable.append(label)
            state = f"unreachable ({'timeout' if status == 'timeout' else f'exit {status}'})"
        environments = ", ".join(system.get("logs", {})) or "none"
        lines.append(f"{label}: {state}, {len(system['read'])} reads, logs: {environments}")
    for line in lines:
        print(line)
    if name is None:
        strip = f"systems: {', '.join(unreachable)} unreachable" if unreachable else ""
        readout.write(repo, "systems", strip=strip, note="\n".join(lines), stale_after=STALE_AFTER)
    return 1 if refused else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("command", choices=["check", "probe", "list"])
    parser.add_argument("--name", help="probe one system only (probe)")
    parser.add_argument("--repo", default=str(HERE.parent), help="repository root (default: this one)")
    args = parser.parse_args()
    repo = Path(args.repo).resolve()
    if args.command == "check":
        return cmd_check(repo)
    if args.command == "list":
        return cmd_list(repo)
    return cmd_probe(repo, args.name)


if __name__ == "__main__":
    sys.exit(main())

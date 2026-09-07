#!/usr/bin/env python3
"""What a lane started in Docker, found by ownership and removed by it.

A lane labels what only it uses with `colloid.run` and `colloid.lane`, labels
what the run shares with `colloid.run` alone, or gives a compose stack the
project name `<run>-<lane>`. This module finds those resources and removes
them — never anything else. A compose project is matched only when it is
exactly a lane's project name, so a stranger's `app-foo` is safe from a run
named `app`. Containers that carry some other tool's ownership (another
compose project, a testcontainers session) are only ever named, so a lead
can see an orphan without the scaffold touching what it does not own.

Every command runs `docker` with a deadline. When it is not installed, the
daemon is down, or it hangs, queries answer empty and removals report
nothing removed, and the caller says so — a number that counts intent is
not evidence that a destructive step happened.
"""

from __future__ import annotations

import shutil
import subprocess

LABEL_RUN = "colloid.run"
LABEL_LANE = "colloid.lane"
TIMEOUT = 10


class Unreachable(Exception):
    """docker could not be asked: missing, down, or past its deadline."""


def _docker(*args: str) -> list[str]:
    """Lines of a successful docker command; raises when it cannot answer."""
    if not shutil.which("docker"):
        raise Unreachable("docker is not installed")
    try:
        result = subprocess.run(["docker", *args], text=True, capture_output=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired as exc:
        raise Unreachable(f"docker did not answer within {TIMEOUT}s") from exc
    if result.returncode != 0:
        raise Unreachable((result.stderr or result.stdout).strip() or f"docker {args[0]} failed")
    return [line for line in result.stdout.splitlines() if line]


def _query(*args: str) -> list[str]:
    try:
        return _docker(*args)
    except Unreachable:
        return []


def project_name(run: str, lane: str) -> str:
    return f"{run}-{lane}"


def owned(run: str, lanes: list[str], lane: str | None = None) -> dict[str, list[str]]:
    """Ids of what a run, or one of its lanes, owns.

    `lanes` names every lane in the run, so compose projects are matched
    exactly. With `lane` given, only that lane's resources are returned:
    the label filter ANDs both keys, so a resource the run shares (labelled
    `colloid.run` only) is never swept by a lane-scoped reap.
    """
    filters = [f"label={LABEL_RUN}={run}"]
    if lane:
        filters.append(f"label={LABEL_LANE}={lane}")
    label_args = [arg for f in filters for arg in ("--filter", f)]
    found = {
        "containers": _query("ps", "-aq", *label_args),
        "networks": _query("network", "ls", "-q", *label_args),
        "volumes": _query("volume", "ls", "-q", *label_args),
    }
    projects = [project_name(run, lane)] if lane else [project_name(run, name) for name in lanes]
    for project in sorted(set(projects)):
        compose = ["--filter", f"label=com.docker.compose.project={project}"]
        found["containers"] += _query("ps", "-aq", *compose)
        found["networks"] += _query("network", "ls", "-q", *compose)
        found["volumes"] += _query("volume", "ls", "-q", *compose)
    return {kind: sorted(set(ids)) for kind, ids in found.items()}


def reap(run: str, lanes: list[str], lane: str | None = None) -> dict[str, list[str]]:
    """Remove what `owned` finds; return what was removed and what was not.

    Keys: containers, networks, volumes — the ids actually removed — and
    `failed`, one line per removal docker refused or could not be asked.
    """
    found = owned(run, lanes, lane)
    result: dict[str, list[str]] = {"containers": [], "networks": [], "volumes": [], "failed": []}
    steps = (("containers", ("rm", "-f")), ("networks", ("network", "rm")), ("volumes", ("volume", "rm", "-f")))
    for kind, command in steps:
        ids = found[kind]
        if not ids:
            continue
        try:
            _docker(*command, *ids)
            result[kind] = ids
        except Unreachable as exc:
            result["failed"].append(f"{kind} {' '.join(ids)}: {exc}")
    return result


def removed_count(result: dict[str, list[str]]) -> int:
    return sum(len(result[kind]) for kind in ("containers", "networks", "volumes"))


def summary(result: dict[str, list[str]]) -> str:
    text = f"reaped {removed_count(result)} docker resource(s)"
    if result["failed"]:
        text += "; NOT removed: " + "; ".join(result["failed"])
    return text


def foreign_orphans() -> list[str]:
    """Test containers nobody is reaping: testcontainers sessions with no Ryuk.

    Named so a lead can see them; never removed here, since the scaffold
    does not own them.
    """
    rows = _query("ps", "--filter", "label=org.testcontainers=true",
                  "--format", "{{.Names}}\t{{.Label \"org.testcontainers.session-id\"}}\t{{.RunningFor}}")
    reapers = set()
    for name in _query("ps", "--format", "{{.Names}}", "--filter", "name=testcontainers-ryuk"):
        reapers.add(name.removeprefix("testcontainers-ryuk-"))
    orphans = []
    for row in rows:
        parts = row.split("\t")
        if len(parts) < 3:
            continue
        name, session, age = parts[0], parts[1], parts[2]
        if session and session not in reapers and not name.startswith("testcontainers-ryuk"):
            orphans.append(f"{name} ({age}, testcontainers session {session[:8]} with no reaper)")
    return orphans

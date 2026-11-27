#!/usr/bin/env python3
"""Run relink-sessions.py on a throwaway transcript store.

Covers the local move it was written for and the cross-machine copy: history
relinked for another host, where the new path must be written exactly as given,
since this machine's symlinks (macOS links /home elsewhere) say nothing about
the other host's.
"""

import json
import os
import pathlib
import subprocess
import sys
import tempfile

here = pathlib.Path(__file__).resolve().parent
tool = here / "relink-sessions.py"
fails = 0


def check(name, ok, detail=""):
    global fails
    if ok:
        print(f"ok   {name}")
    else:
        fails += 1
        print(f"FAIL {name}{': ' + detail if detail else ''}", file=sys.stderr)


def run(store, *args):
    env = dict(os.environ, CLAUDE_CONFIG_DIR=str(store))
    return subprocess.run([sys.executable, str(tool), *args], env=env, capture_output=True, text=True)


with tempfile.TemporaryDirectory() as tmp:
    tmp = pathlib.Path(tmp).resolve()
    store = tmp / "store"
    old = tmp / "Projects" / "Acme" / "app"
    old.mkdir(parents=True)
    source = store / "projects" / str(old).replace("/", "-").replace(".", "-")
    (source / "s1" / "subagents").mkdir(parents=True)
    entry = {"cwd": str(old), "file": f"{old}/src/a.ts", "sibling": f"{old}-legacy/b.ts"}
    (source / "s1.jsonl").write_text(json.dumps(entry) + "\n")
    (source / "s1" / "subagents" / "agent-1.jsonl").write_text(json.dumps({"cwd": str(old)}) + "\n")
    os.utime(source / "s1.jsonl", (1_700_000_000, 1_700_000_000))

    # A path on another host, written as that host spells it. On this Mac /home
    # is a link, so resolving it here would rename both the folder and every cwd.
    remote = "/home/openclawops/Projects/Acme/app"
    remote_slug = "-home-openclawops-Projects-Acme-app"
    r = run(store, str(old), remote, "--remote", "--apply")
    check("a relink for another host exits 0", r.returncode == 0, r.stderr)
    target = store / "projects" / remote_slug
    check("the folder is the other host's slug, unresolved here", (target / "s1.jsonl").is_file(),
          str(sorted(p.name for p in (store / "projects").iterdir())))
    if (target / "s1.jsonl").is_file():
        got = json.loads((target / "s1.jsonl").read_text())
        check("each cwd names the other host's path", got["cwd"] == remote, got["cwd"])
        check("a file under the project is rewritten", got["file"] == f"{remote}/src/a.ts", got["file"])
        check("a sibling project is left alone", got["sibling"] == f"{old}-legacy/b.ts", got["sibling"])
        check("the session keeps its date for /resume", int((target / "s1.jsonl").stat().st_mtime) == 1_700_000_000)
    check("subagent transcripts come along", (target / "s1" / "subagents" / "agent-1.jsonl").is_file())
    check("the source folder is kept", (source / "s1.jsonl").is_file())

    r = run(store, str(old), "relative/path", "--remote")
    check("a relative path for another host is refused", r.returncode != 0 and "absolute" in r.stderr, r.stderr)

    # The local move: the new path exists here and is resolved as Claude Code does.
    new = tmp / "Projects" / "Acme2" / "app"
    new.mkdir(parents=True)
    r = run(store, str(old), str(new), "--apply")
    check("a local relink exits 0", r.returncode == 0, r.stderr)
    local = store / "projects" / str(new).replace("/", "-")
    check("a local relink writes the new folder", (local / "s1.jsonl").is_file())

if fails:
    print(f"{fails} failed", file=sys.stderr)
    sys.exit(1)
print("relink-sessions tests passed")

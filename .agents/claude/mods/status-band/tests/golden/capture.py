#!/usr/bin/env python3
"""Capture the status strip's own output as the band's expected values.

Usage: capture.py <statusline.sh> <out.ts>

Runs a copy of the strip script given (the bash status strip this band
replaced; `git show 36a3177:.agents/claude/statusline.sh` holds it) once per
fixture below, in throwaway git repositories, with `date` pinned to NOW, and
writes every capture to <out.ts>: the fixture's inputs, the strip's raw bytes,
and the same output split into runs of one colour and weight per row.

For every input the band reads from outside itself, the capture records what
the real tool answered in the same state, so the band's tests replay real
answers rather than invented ones: `git status --porcelain=v2 --branch` (and
`git rev-parse --short HEAD` on a detached head) in the fixture's folder, and
`readout.py strip` in the fixture's checkout when its readout folder exists.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

NOW = 1764300000
HOME = "/Users/fixture"
MODEL = {"display_name": "Fable 5.1"}
GIT_ENV = {
    "GIT_AUTHOR_NAME": "fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
    "GIT_COMMITTER_NAME": "fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
    "GIT_AUTHOR_DATE": "2025-11-28T00:00:00Z", "GIT_COMMITTER_DATE": "2025-11-28T00:00:00Z",
    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
}


def fixtures():
    """(name, status, env, folder, readout) for each segment and value class."""
    def status(folder="plain", **extra):
        return {"transcript_path": f"{HOME}/.claude/projects/p/s.jsonl",
                "workspace": {"current_dir": folder}, "model": MODEL, **extra}

    rows = [
        ("plain folder", status(), {}, "plain", None),
        ("git branch and dirty count", status("tree"), {}, "tree", None),
        ("git clean, no upstream", status("clean"), {}, "clean", None),
        ("git ahead and behind", status("app"), {}, "app", None),
        ("git detached head", status("detached"), {}, "detached", None),
        ("lines both zero", status(cost={"total_lines_added": 0, "total_lines_removed": 0}), {}, "plain", None),
        ("lines added and removed", status(cost={"total_lines_added": 156, "total_lines_removed": 23}), {}, "plain", None),
        ("lines added only", status(cost={"total_lines_added": 5, "total_lines_removed": 0}), {}, "plain", None),
        ("pr approved", status(pr={"number": 41, "review_state": "approved"}), {}, "plain", None),
        ("pr changes requested", status(pr={"number": 42, "review_state": "changes_requested"}), {}, "plain", None),
        ("pr draft", status(pr={"number": 43, "review_state": "draft"}), {}, "plain", None),
        ("pr pending", status(pr={"number": 44, "review_state": "pending"}), {}, "plain", None),
        ("worktree from workspace", status(workspace={"current_dir": "plain", "git_worktree": "feature-x"}), {}, "plain", None),
        ("worktree from worktree.name", status(worktree={"name": "wt-name"}), {}, "plain", None),
        ("session name", status(session_name="fix the login"), {}, "plain", None),
        ("duration 12m", status(cost={"total_duration_ms": 720000}), {}, "plain", None),
        ("duration 1h12m", status(cost={"total_duration_ms": 4320000.5}), {}, "plain", None),
        ("duration 0 hidden", status(cost={"total_duration_ms": 0}), {}, "plain", None),
        ("vim mode", status(vim={"mode": "INSERT"}), {}, "plain", None),
        ("effort", status(effort={"level": "high"}), {}, "plain", None),
        ("thinking on", status(thinking={"enabled": True}), {}, "plain", None),
        ("thinking off", status(thinking={"enabled": False}), {}, "plain", None),
        ("fast mode", status(fast_mode=True), {}, "plain", None),
        ("context under 60 in K", status(context_window={"used_percentage": 42.7, "context_window_size": 200000,
                                                          "current_usage": {"input_tokens": 80000, "cache_creation_input_tokens": 1500,
                                                                            "cache_read_input_tokens": 3999}}), {}, "plain", None),
        ("context at 60", status(context_window={"used_percentage": 60, "context_window_size": 1000000,
                                                 "current_usage": {"input_tokens": 600000}}), {}, "plain", None),
        ("context at 85 past a million", status(context_window={"used_percentage": 85, "context_window_size": 1250000,
                                                                "current_usage": {"input_tokens": 1062500}}), {}, "plain", None),
        ("context default size", status(context_window={"used_percentage": 10, "current_usage": {"input_tokens": 20000}}), {}, "plain", None),
        ("context with no usage", status(context_window={"used_percentage": 0}), {}, "plain", None),
        ("5h under 70", status(rate_limits={"five_hour": {"used_percentage": 42}}), {}, "plain", None),
        ("5h at 70 with reset", status(rate_limits={"five_hour": {"used_percentage": 70.9, "resets_at": NOW + 2 * 3600 + 10 * 60 + 5}}), {}, "plain", None),
        ("5h at 90, reset passed", status(rate_limits={"five_hour": {"used_percentage": 90, "resets_at": NOW - 60}}), {}, "plain", None),
        ("7d", status(rate_limits={"seven_day": {"used_percentage": 18}}), {}, "plain", None),
        ("5h and 7d", status(rate_limits={"five_hour": {"used_percentage": 5, "resets_at": NOW + 59}, "seven_day": {"used_percentage": 95}}), {}, "plain", None),
        ("style default hidden", status(output_style={"name": "default"}), {}, "plain", None),
        ("style shown", status(output_style={"name": "colloid"}), {}, "plain", None),
        ("missing model", {k: v for k, v in status().items() if k != "model"}, {}, "plain", None),
        ("badge from CLAUDE_PROFILE", status(), {"CLAUDE_PROFILE": "work"}, "plain", None),
        ("badge from a named transcript folder", status(transcript_path=f"{HOME}/.claude-personal/projects/p/s.jsonl"), {}, "plain", None),
        ("badge from CLAUDE_PROFILE in a named folder", status(transcript_path=f"{HOME}/.claude-guest/projects/p/s.jsonl"),
         {"CLAUDE_PROFILE": "guest"}, "plain", None),
        ("badge from CLAUDE_CONFIG_DIR", status(transcript_path=""), {"CLAUDE_CONFIG_DIR": f"{HOME}/.claude-family"}, "plain", None),
        ("no badge for the default CLAUDE_CONFIG_DIR", status(transcript_path=""), {"CLAUDE_CONFIG_DIR": f"{HOME}/.claude"}, "plain", None),
        ("no badge for the default folder", status(), {}, "plain", None),
        ("everything at once", status("app", transcript_path=f"{HOME}/.claude-personal/projects/p/s.jsonl",
                                      cost={"total_lines_added": 156, "total_lines_removed": 23, "total_duration_ms": 4320000,
                                            "total_cost_usd": 3.25},
                                      pr={"number": 41, "review_state": "approved"}, workspace={"current_dir": "app", "git_worktree": "feat"},
                                      session_name="session name", vim={"mode": "NORMAL"}, effort={"level": "high"},
                                      thinking={"enabled": True}, fast_mode=True,
                                      context_window={"used_percentage": 36.7, "context_window_size": 1000000,
                                                      "current_usage": {"input_tokens": 367000}},
                                      rate_limits={"five_hour": {"used_percentage": 42, "resets_at": NOW + 7800},
                                                   "seven_day": {"used_percentage": 18}},
                                      output_style={"name": "colloid"}), {}, "app", None),
        # Badge names that hold an @: the band cuts them there (acceptance 2).
        ("email in CLAUDE_PROFILE", status(), {"CLAUDE_PROFILE": "me@example.com"}, "plain", None),
        ("email in a folder name", status(transcript_path=f"{HOME}/.claude-a@b.io/projects/p/s.jsonl"), {}, "plain", None),
        # Row 3: the readout folder in the checkout running the strip.
        ("readouts: no folder", status(session_id="sess-1"), {}, "plain", "none"),
        ("readouts: empty folder", status(session_id="sess-1"), {}, "plain", "empty"),
        ("readouts: one repository-wide, another session's hidden", status(), {}, "plain", "global"),
        ("readouts: the payload's own session", status(session_id="sess-1"), {}, "plain", "session"),
        ("readouts: two, backslash kept", status(), {}, "plain", "two"),
        ("readouts: reader failed", status(), {}, "plain", "failed"),
    ]
    return rows


def run(argv, cwd=None, env=None, check=True):
    done = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True)
    if check and done.returncode != 0:
        raise SystemExit(f"capture: {argv} failed: {done.stderr}")
    return done


def git(folder, *args):
    return run(["git", "-C", str(folder), *args], env={**os.environ, **GIT_ENV})


def make_folders(root):
    (root / "plain").mkdir()
    for name in ("tree", "clean", "detached"):
        (root / name).mkdir()
    for name in ("tree", "clean", "detached"):
        git(root / name, "init", "-q", "-b", "trunk")
        (root / name / "a.txt").write_text("a\n")
        git(root / name, "add", "a.txt")
        git(root / name, "commit", "-q", "-m", "base")
    (root / "tree" / "new.txt").write_text("x\n")
    (root / "detached" / "a.txt").write_text("b\n")
    git(root / "detached", "commit", "-qam", "second")
    git(root / "detached", "checkout", "-q", "--detach", "HEAD~1")
    # app: tracks origin/trunk, two commits ahead and one behind.
    git(root, "init", "-q", "--bare", "-b", "trunk", "origin.git")
    git(root, "clone", "-q", str(root / "origin.git"), "app")
    (root / "app" / "a.txt").write_text("a\n")
    git(root / "app", "add", "a.txt")
    git(root / "app", "commit", "-q", "-m", "base")
    git(root / "app", "push", "-q", "origin", "trunk")
    git(root, "clone", "-q", str(root / "origin.git"), "other")
    (root / "other" / "b.txt").write_text("b\n")
    git(root / "other", "add", "b.txt")
    git(root / "other", "commit", "-q", "-m", "theirs")
    git(root / "other", "push", "-q", "origin", "trunk")
    for n in (1, 2):
        (root / "app" / f"m{n}.txt").write_text(f"{n}\n")
        git(root / "app", "add", f"m{n}.txt")
        git(root / "app", "commit", "-q", "-m", f"mine {n}")
    git(root / "app", "fetch", "-q")


def make_checkout(root, strip, repo):
    checkout = root / "checkout"
    (checkout / ".agents/claude").mkdir(parents=True)
    (checkout / ".agents/hooks/lib").mkdir(parents=True)
    shutil.copy(strip, checkout / ".agents/claude/statusline.sh")
    for lib in ("config.py", "readout.py"):
        shutil.copy(repo / ".agents/hooks/lib" / lib, checkout / ".agents/hooks/lib" / lib)
    return checkout


def set_readouts(checkout, kind):
    folder = checkout / ".agents/.readout"
    reader = checkout / ".agents/hooks/lib/readout.py"
    shutil.rmtree(folder, ignore_errors=True)
    if kind == "none":
        return
    folder.mkdir()

    def write(name, text, session=None):
        args = ["python3", str(reader), "write", name, "--repo", str(checkout), "--strip", text]
        run(args + (["--session", session] if session else []))

    if kind in ("global", "session", "two", "failed"):
        write("owed", "2 replies owed")
        write("other", "hidden", "elsewhere")
    if kind == "session":
        write("mine", "my own readout", "sess-1")
    if kind == "two":
        write("second", "back\\slash")


def segments(raw):
    """The strip's output as rows of runs: text, colour (#rrggbb or None), bold."""
    rows = []
    for line in raw.split("\n")[:-1] if raw.endswith("\n") else raw.split("\n"):
        runs, color, bold = [], None, False
        for part in re.split(r"(\x1b\[[0-9;]*m)", line):
            code = re.fullmatch(r"\x1b\[([0-9;]*)m", part)
            if code:
                params = code.group(1)
                if params in ("0", ""):
                    color, bold = None, False
                elif params == "1":
                    bold = True
                elif params.startswith("38;2;"):
                    r, g, b = (int(x) for x in params.split(";")[2:5])
                    color = f"#{r:02x}{g:02x}{b:02x}"
                else:
                    raise SystemExit(f"capture: an escape the parser does not know: {params!r}")
            elif part:
                if runs and runs[-1]["color"] == color and runs[-1]["bold"] == bold:
                    runs[-1]["text"] += part
                else:
                    runs.append({"text": part, "color": color, "bold": bold})
        rows.append(runs)
    return rows


def git_answers(folder):
    """What the band's git commands answer in the folder, by argv joined with spaces."""
    answers = {}
    env = {**os.environ, "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"}
    status = run(["git", "status", "--porcelain=v2", "--branch"], cwd=folder, env=env, check=False)
    answers["git status --porcelain=v2 --branch"] = {"exitCode": status.returncode, "stdout": status.stdout,
                                                    "stderr": status.stderr.replace(str(folder.parent), "/fixture")}
    if "# branch.head (detached)" in status.stdout:
        short = run(["git", "rev-parse", "--short", "HEAD"], cwd=folder, env=env)
        answers["git rev-parse --short HEAD"] = {"exitCode": 0, "stdout": short.stdout, "stderr": ""}
    return answers


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: capture.py <statusline.sh> <out.ts>")
    strip, out = Path(sys.argv[1]).resolve(), Path(sys.argv[2])
    repo = Path(__file__).resolve().parents[6]
    scratch = Path(tempfile.mkdtemp(prefix="status-band-capture."))
    try:
        root = scratch / "fixture"
        root.mkdir()
        bin_dir = scratch / "bin"
        bin_dir.mkdir()
        (bin_dir / "date").write_text(f"#!/bin/sh\necho {NOW}\n")
        (bin_dir / "date").chmod(0o755)
        make_folders(root)
        checkout = make_checkout(scratch, strip, repo)
        jq = shutil.which("jq")
        if jq is None:
            raise SystemExit("capture: the strip needs jq on PATH")
        path = f"{bin_dir}:{Path(jq).parent}:/usr/bin:/bin"
        captures = []
        for name, status, env, folder, readout in fixtures():
            status = json.loads(json.dumps(status))
            status["workspace"]["current_dir"] = str(root / folder)
            set_readouts(checkout, readout or "none")
            reader = checkout / ".agents/hooks/lib/readout.py"
            kept = reader.read_text()
            if readout == "failed":
                reader.write_text("import sys\nsys.exit(3)\n")
            payload = json.dumps(status)
            env_run = {"HOME": HOME, "PATH": path, "GIT_CEILING_DIRECTORIES": str(scratch), "LC_ALL": "C", **env}
            raw = subprocess.run(["bash", str(checkout / ".agents/claude/statusline.sh")], input=payload,
                                 env=env_run, capture_output=True, text=True)
            if raw.returncode != 0 or raw.stderr:
                raise SystemExit(f"capture: the strip failed on {name!r}: {raw.stderr}")
            answers = git_answers(root / folder) if folder != "plain" else {}
            reader_answer = None
            if readout not in (None, "none"):
                done = subprocess.run(["python3", str(reader), "strip", str(checkout), status.get("session_id", "")],
                                      capture_output=True, text=True)
                reader_answer = {"exitCode": done.returncode, "stdout": done.stdout}
            reader.write_text(kept)
            shown = json.loads(payload.replace(str(root), "/fixture"))
            captures.append({
                "name": name,
                "status": shown,
                "env": {"HOME": HOME, **env},
                "now": NOW * 1000,
                "git": answers if folder != "plain" else None,
                "readouts": None if readout in (None, "none") else {"answer": reader_answer},
                "raw": raw.stdout,
                "rows": segments(raw.stdout),
            })
        body = json.dumps(captures, indent=2, ensure_ascii=False)
        out.write_text(
            "// Generated by capture.py from the bash status strip; do not edit by hand.\n"
            "// Each capture holds a fixture's inputs, the strip's raw output and its runs.\n\n"
            "export type Run = { text: string; color: string | null; bold: boolean }\n"
            "export type Answer = { exitCode: number; stdout: string; stderr?: string }\n"
            "export type Capture = {\n"
            "  name: string\n"
            "  status: Record<string, unknown>\n"
            "  env: Record<string, string>\n"
            "  now: number\n"
            "  git: Record<string, Answer> | null\n"
            "  readouts: { answer: Answer | null } | null\n"
            "  raw: string\n"
            "  rows: Run[][]\n"
            "}\n\n"
            f"export const CAPTURES: readonly Capture[] = {body}\n",
            encoding="utf-8")
    finally:
        shutil.rmtree(scratch)


if __name__ == "__main__":
    main()

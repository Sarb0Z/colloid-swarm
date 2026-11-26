#!/usr/bin/env python3
"""Refuse a commit, a commit message, or a push that carries a private name.

Usage:
  leak_gate.py staged               added lines, paths, and author of the staged commit
  leak_gate.py message <file>       a commit message file
  leak_gate.py push <remote> [url]  every new commit a push sends (git's pre-push stdin)
  leak_gate.py history <repo>       every commit of a repository, for audits
  leak_gate.py classify             machine names that no list classifies

The name list lives outside the repository, in $COLLOID_LEAK_DIR (default
~/.config/colloid): `satellites.txt` holds `name==>replacement` rows, and
`port.json` holds `own`, `common_words`, `reviewed`, `authors` and `sources`.
A private name is always a finding. A separator variant of one, or a common word
in any case, is a finding until its id (sha256 of the path or `message`, a
newline, and the stripped line; first 16 hex characters) is in `reviewed`.
Findings go to stderr and the exit status is 1; a clean run exits 0. With no
config folder nothing can be checked: one stderr line says so and the exit is 0.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import NoReturn

REPLACEMENT_SAFE = re.compile(r"^[A-Za-z0-9._/@-]+$")
WORD_CHAR = re.compile(r"[A-Za-z0-9_]")
VARIANT_SAFE = re.compile(r"^[A-Za-z0-9 _.-]+$")
HUNK = re.compile(r"^@@ -\S+ \+(\d+)")
IDENT_STAMP = re.compile(r" \d+ [+-]\d{4}$")
ALL_ZEROS = re.compile(r"^0+$")
# Plain-text diffs with fixed prefixes, whatever the user's diff configuration says.
DIFF_FLAGS = ("-U0", "--no-renames", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/")


def fail(message: str) -> NoReturn:
    raise SystemExit(f"leak-gate: {message}")


def run_git(repo, *args):
    """The real git runner; a failing command stops the gate with its stderr."""
    result = subprocess.run(["git", "-c", "core.quotepath=off", "-C", str(repo), *args],
                            capture_output=True, text=True, errors="replace")
    if result.returncode:
        fail(f"`git {' '.join(args)}` exited {result.returncode}: {result.stderr.strip()}")
    return result.stdout


# ── name matching, as in port-public.py ─────────────────────────────────────

def bounded(name):
    """A name as a regex that will not match inside a longer word.

    Only an edge that is itself a word character gets the check, so `-Users-alice-`
    still matches in `-Users-alice-Projects`."""
    before = r"(?<![A-Za-z0-9_])" if WORD_CHAR.match(name[0]) else ""
    after = r"(?![A-Za-z0-9_])" if WORD_CHAR.match(name[-1]) else ""
    return before + re.escape(name) + after


def name_pattern(names):
    """One case-insensitive regex matching any of the names exactly, longest first."""
    names = sorted(names, key=len, reverse=True)
    return re.compile("|".join(map(bounded, names)), re.I) if names else None


def variant_pattern(names):
    """Any spelling of a name that adds, drops, or swaps a separator: `Acme Co`, `AcmeCo2`, `acme_co`.

    It is unbounded, so it also flags a name inside an unrelated word; such a
    line needs a review id like a common word does."""
    cores = {re.sub(r"[-_ .]", "", n) for n in names if VARIANT_SAFE.match(n)}
    flexible = ["[-_ .]?".join(map(re.escape, c)) for c in sorted(cores, key=len, reverse=True) if c]
    return re.compile("|".join(flexible), re.I) if flexible else None


def search(pattern, line):
    return pattern.search(line) if pattern else None


# ── config ──────────────────────────────────────────────────────────────────

def load_config(folder):
    rows_file, json_file = folder / "satellites.txt", folder / "port.json"
    for needed in (rows_file, json_file):
        if not needed.is_file():
            fail(f"{needed} is missing from the leak list folder")
    try:
        config = json.loads(json_file.read_text())
    except json.JSONDecodeError as error:
        fail(f"{json_file}:{error.lineno}: not valid JSON: {error.msg}")
    if not isinstance(config, dict):
        fail(f"{json_file}:1: the top level must be a JSON object")
    rows = []
    for number, line in enumerate(rows_file.read_text().splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        name, sep, replacement = line.partition("==>")
        if not sep or not name or not REPLACEMENT_SAFE.match(replacement):
            fail(f"{rows_file}:{number}: write `name==>replacement`; a replacement uses only "
                 "letters, digits, `.`, `_`, `/`, `@` and `-`, so HTML escaping cannot change it")
        rows.append((name, replacement))
    config["rows"] = sorted(rows, key=lambda row: -len(row[0]))
    return config


class Matcher:
    def __init__(self, config):
        names = [n for n, _ in config["rows"]]
        words = config.get("common_words", [])
        self.blocked, self.variants = name_pattern(names), variant_pattern(names)
        self.common = re.compile("|".join(map(bounded, words)), re.I) if words else None
        self.reviewed = set(config.get("reviewed", []))
        self.authors = set(config.get("authors", []))

    def line(self, where, number, scope, text):
        """The finding for one line, or None when it is clean or reviewed."""
        if hit := search(self.blocked, text):
            return f"{where}:{number}: `{hit[0]}`"
        if hit := search(self.variants, text) or search(self.common, text):
            key = hashlib.sha256(f"{scope}\n{text.strip()}".encode()).hexdigest()[:16]
            if key not in self.reviewed:
                return f"{where}:{number}: `{hit[0]}` unreviewed (reviewed id {key}): {text.strip()[:120]}"
        return None

    def text(self, where, scope, text):
        found = (self.line(where, n, scope, line) for n, line in enumerate(text.splitlines(), 1))
        return [leak for leak in found if leak]

    def identity(self, where, who):
        return [] if who in self.authors else [f"{where}: identity `{who}` is not in port.json `authors`"]

    def diff(self, where, diff):
        found = (self.line(f"{where}{path}", number, path, line) for path, number, line in added_lines(diff))
        return [leak for leak in found if leak]

    def paths(self, where, listing):
        return [leak for path in filter(None, listing.split("\0")) for leak in self.text(f"{where}path {path}", "path", path)]


def added_lines(diff):
    """Yield (path, new line number, text) for each line a unified diff adds."""
    header, path, number = False, None, 0
    for line in diff.split("\n"):
        if line.startswith("diff --git "):
            header = True
        elif header and line.startswith("+++ "):
            path = None if line == "+++ /dev/null" else line[4:].strip('"')[2:]
        elif m := HUNK.match(line):
            header, number = False, int(m[1])
        elif not header and line.startswith("+"):
            yield path, number, line[1:]
            number += 1


# ── modes ───────────────────────────────────────────────────────────────────

def ident(git, repo, which):
    return IDENT_STAMP.sub("", git(repo, "var", which).strip())


def scan_staged(matcher, git):
    leaks = matcher.identity("author", ident(git, ".", "GIT_AUTHOR_IDENT"))
    leaks += matcher.diff("", git(".", "diff", "--cached", *DIFF_FLAGS))
    leaks += matcher.paths("", git(".", "diff", "--cached", "--name-only", "-z", "--no-renames", "--diff-filter=d"))
    return leaks


def scan_message(matcher, git, file):
    comment = git(".", "config", "--default", "#", "--get", "core.commentChar").strip()
    lines = file.read_text(errors="replace").splitlines()
    scissors = f"{comment if len(comment) == 1 else '#'} ------------------------ >8 ------------------------"
    # `git commit -v` appends the diff below the scissors line; git drops it, so it is not the message.
    return matcher.text("message", "message", "\n".join(lines[:lines.index(scissors)] if scissors in lines else lines))


def scan_commit(matcher, git, repo, sha):
    tag = f"commit {sha[:12]} "
    author, committer, body = git(repo, "log", "-1", "--format=%an <%ae>%x00%cn <%ce>%x00%B", sha).split("\0", 2)
    leaks = [leak for who in sorted({author, committer}) for leak in matcher.identity(tag.strip(), who)]
    leaks += matcher.text(f"{tag}message", "message", body)
    leaks += matcher.diff(tag, git(repo, "diff-tree", "-p", "-r", "--root", "--no-commit-id", *DIFF_FLAGS, sha))
    leaks += matcher.paths(tag, git(repo, "diff-tree", "-r", "--root", "--no-commit-id", "--name-only", "-z",
                                    "--no-renames", "--diff-filter=d", sha))
    return leaks


def push_commits(git, stdin, remote):
    """The commits a push sends: not on the remote ref, and in no remote-tracking ref of `remote`."""
    shas = []
    for line in stdin.read().splitlines():
        fields = line.split()
        if len(fields) != 4:
            fail(f"unreadable pre-push line: {line!r}")
        _, local, _, remote_sha = fields
        if ALL_ZEROS.match(local):
            continue
        known = [] if ALL_ZEROS.match(remote_sha) else [remote_sha]
        shas += git(".", "rev-list", local, "--not", f"--remotes={remote}", *known).split()
    return list(dict.fromkeys(shas))


# ── classify, as in port-public.py ──────────────────────────────────────────

def source(sources, key):
    """A configured name source; one that is missing stops the check rather than reading as empty."""
    if key not in sources:
        fail(f"port.json `sources` has no `{key}`")
    path = Path(os.path.expanduser(sources[key]))
    if not path.exists():
        fail(f"name source `{key}` ({path}) does not exist; a missing source would hide its names")
    return path


def remote_names(url):
    """The names a remote URL carries: GitHub owner and repository, or any other server's host."""
    if github := re.search(r"github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?$", url):
        return set(github.groups())
    if not url.startswith((".", "/")) and (
            host := re.match(r"(?:[a-z][a-z+]*://)?(?:[^@/\s]+@)?([^:/\s]+)[:/]", url)):
        return {host[1]}
    return set()                        # a local path


def machine_names(sources, git):
    names = set()
    projects = source(sources, "projects")
    for folder in sorted(p for p in projects.iterdir() if p.is_dir() and not p.name.startswith(".")):
        names.add(folder.name)
        for repo in [folder, *(p for p in folder.iterdir() if p.is_dir() and not p.name.startswith("."))]:
            if not (repo / ".git").exists():
                continue
            names.add(repo.name)
            for line in git(repo, "remote", "-v").splitlines():
                names |= remote_names(line.split()[1])
    for identity in json.loads(source(sources, "identities").read_text())["identities"].values():
        names.update(identity["github_org"])
    names.update(re.findall(r"^\| \[([^\]]+)\]", source(sources, "registry").read_text(), re.M))
    return names


def unclassified(config, git):
    found = {n.lower() for n in machine_names(config.get("sources", {}), git)}
    known = ({n.lower() for n, _ in config["rows"]} | {n.lower() for n in config.get("own", [])}
             | {n.lower() for n in config.get("common_words", [])})
    return [f"name `{n}` is on this machine and in none of satellites.txt, `own` or `common_words`"
            for n in sorted(found - known)]


# ── entry ───────────────────────────────────────────────────────────────────

def parse(argv):
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    modes = parser.add_subparsers(dest="mode", required=True)
    modes.add_parser("staged", help="scan the staged commit")
    modes.add_parser("message", help="scan a commit message file").add_argument("file", type=Path)
    push = modes.add_parser("push", help="scan the commits a push sends (reads pre-push stdin)")
    push.add_argument("remote")
    push.add_argument("url", nargs="?")
    modes.add_parser("history", help="scan a repository's whole history").add_argument("repo", type=Path)
    modes.add_parser("classify", help="list machine names no list classifies")
    return parser.parse_args(argv)


def main(argv, env, home, stdin, git):
    args = parse(argv)
    folder = Path(env.get("COLLOID_LEAK_DIR") or home / ".config" / "colloid")
    if not folder.is_dir():
        print(f"leak-gate: no leak list was found at {folder}; nothing was checked", file=sys.stderr)
        return 0
    config = load_config(folder)
    matcher = Matcher(config)
    if args.mode == "staged":
        leaks = scan_staged(matcher, git)
    elif args.mode == "message":
        leaks = scan_message(matcher, git, args.file)
    elif args.mode == "push":
        leaks = [leak for sha in push_commits(git, stdin, args.remote) for leak in scan_commit(matcher, git, ".", sha)]
    elif args.mode == "history":
        leaks = [leak for sha in git(args.repo, "rev-list", "--all").split()
                 for leak in scan_commit(matcher, git, args.repo, sha)]
    else:
        leaks = unclassified(config, git)
    if leaks:
        print("\n".join(leaks), file=sys.stderr)
        print(f"leak-gate: {len(leaks)} finding(s); nothing was let through", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], os.environ, Path.home(), sys.stdin, run_git))

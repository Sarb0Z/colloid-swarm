#!/usr/bin/env python3
"""Build the public copy of this repository as a filtered replay of its history.

Usage:
  port-public.py check                  generated starters match the tree
  port-public.py refresh                rewrite the generated starters
  port-public.py build <out> [--against <url>]
                                        filter history into <out>, gate it, verify it
  --repo <path>                         the private repository (default: this one)

`.agents/public/` holds the inputs. `satellites.txt` maps each private name to
its public replacement; `port.json` lists the dropped and allowed paths, the
mailmap, the name sources, and the names that may stay. `tree/` holds starter
files that replace private records in public: each lands at the same path with
`.agents/public/tree/` removed, in every commit that carries it.

A build never trusts its own replacement list to prove itself clean. It builds a
second name list from the operator's machine (`sources` in port.json), fails on
any name nobody classified, then scans every path, blob, message, and identity
of the filtered history. Pushing the result is a separate, approved step.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
PUBLIC = ".agents/public"
TREE = f"{PUBLIC}/tree/"
REPLACEMENT_SAFE = re.compile(r"^[A-Za-z0-9._/@-]+$")
WORD_CHAR = re.compile(r"[A-Za-z0-9_]")
VARIANT_SAFE = re.compile(r"^[A-Za-z0-9 _.-]+$")
DEBT_POINTER = re.compile(r"debt: ([a-z0-9][a-z0-9-]*)")
DEBT_HEADING = re.compile(r"^### ([a-z0-9][a-z0-9-]*)$", re.M)
DEBT_CITATION = re.compile(r"`([a-z0-9][a-z0-9-]*)`")
GENERATED = (".agents/debt-log.md", "demo/scaffold-showcase.html", "demo/scaffold-showcase.artifact.html")


def fail(message):
    raise SystemExit(f"port-public: {message}")


def run(command, cwd=None, data=None):
    """Run a command; a failure stops the port with the command and its stderr."""
    result = subprocess.run(command, cwd=cwd, input=data, capture_output=True)
    if result.returncode:
        fail(f"`{' '.join(map(str, command))}` exited {result.returncode}:\n"
             + result.stderr.decode(errors="replace").strip())
    return result.stdout


def git(repo, *args):
    return run(["git", "-C", str(repo), *args]).decode()


def load_config(repo):
    config = json.loads((repo / PUBLIC / "port.json").read_text())
    rows = []
    for number, line in enumerate((repo / PUBLIC / "satellites.txt").read_text().splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        name, sep, replacement = line.partition("==>")
        if not sep or not name or not REPLACEMENT_SAFE.match(replacement):
            fail(f"satellites.txt:{number}: write `name==>replacement`; a replacement uses only "
                 "letters, digits, `.`, `_`, `/`, `@` and `-`, so HTML escaping cannot change it")
        rows.append((name, replacement))
    config["rows"] = sorted(rows, key=lambda row: -len(row[0]))
    return config


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


# ── generated starters ──────────────────────────────────────────────────────

def dropped(rel, drops):
    """A drop entry ending in `/` removes a folder; any other removes that one file."""
    return any(rel == d or (d.endswith("/") and rel.startswith(d)) for d in drops)


def shipped_copy(repo, dest, config):
    """Copy the tracked working tree, minus dropped paths, with the starters laid over it."""
    for rel in git(repo, "ls-files", "-z").split("\0"):
        if not rel or dropped(rel, config["drop"]) or rel.startswith(PUBLIC + "/"):
            continue
        source, target = repo / rel, dest / rel
        if not source.exists() and not source.is_symlink():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target, follow_symlinks=False)
    starters = repo / TREE
    for source in sorted(p for p in starters.rglob("*") if p.is_file()):
        rel = source.relative_to(starters).as_posix()
        if rel in GENERATED:
            continue
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def debt_starter(repo, shipped, not_pointers):
    """The debt log's header plus every entry shipped code points at, closed over citations.

    A pointer naming no entry fails, unless port.json lists it in
    `debt_not_pointers` (a fixture or a rename table that only looks like one)."""
    text = (repo / ".agents/debt-log.md").read_text()
    starts = [m.start() for m in DEBT_HEADING.finditer(text)]
    header = text[:starts[0]] if starts else text
    sections = {DEBT_HEADING.match(text[s:])[1]: text[s:e].rstrip() + "\n"
                for s, e in zip(starts, starts[1:] + [len(text)])}
    wanted = set()
    for path in shipped.rglob("*"):
        if path.is_file() and not path.is_symlink() and path.suffix != ".html":
            wanted.update(DEBT_POINTER.findall(path.read_text(errors="replace")))
    wanted -= set(not_pointers)
    if dangling := sorted(wanted - sections.keys()):
        fail(f"shipped code points at debt entries the debt log lacks: {dangling}; add the entry, "
             "or list an id that is not a real pointer in port.json `debt_not_pointers`")
    frontier = set(wanted)
    while frontier:
        cited = {i for w in frontier for i in DEBT_CITATION.findall(sections[w]) if i in sections}
        frontier = cited - wanted
        wanted |= frontier
    return header.rstrip() + "\n\n" + "\n".join(sections[w] for w in sections if w in wanted)


def generate(repo):
    """Return {path: text} for every generated starter."""
    out = {}
    config = load_config(repo)
    with tempfile.TemporaryDirectory(prefix="port-public-") as scratch:
        shipped = Path(scratch)
        shipped_copy(repo, shipped, config)
        debt = shipped / ".agents/debt-log.md"
        if (repo / ".agents/debt-log.md").exists():
            out[".agents/debt-log.md"] = debt_starter(repo, shipped, config["debt_not_pointers"])
            debt.parent.mkdir(parents=True, exist_ok=True)
            debt.write_text(out[".agents/debt-log.md"])
        if (shipped / "demo/embed-src.py").exists():
            # embed-src.py rewrites the pages in place, so it starts from the private ones.
            for rel in GENERATED[1:]:
                shutil.copy2(repo / rel, shipped / rel)
            run([sys.executable, str(shipped / "demo/embed-src.py")], cwd=shipped)
            for rel in GENERATED[1:]:
                out[rel] = (shipped / rel).read_text()
    return out


def check(repo):
    if not (repo / PUBLIC / "port.json").exists():
        print(f"port-public: no {PUBLIC}/port.json; this repository ports nothing")
        return
    stale = [rel for rel, text in generate(repo).items()
             if not (repo / TREE / rel).exists() or (repo / TREE / rel).read_text() != text]
    if stale:
        fail(f"generated starters are stale: {stale}; run `python3 .agents/port-public.py refresh`")
    print("port-public: generated starters match the tree")


def refresh(repo):
    for rel, text in generate(repo).items():
        target = repo / TREE / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        print(f"port-public: wrote {TREE}{rel}")


# ── independent name list ───────────────────────────────────────────────────

def source(sources, key):
    """A configured name source; one that is missing stops the port rather than reading as empty."""
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


def machine_names(sources):
    """Names from the operator's machine, built without reading satellites.txt."""
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


def classify(config):
    found = {n.lower() for n in machine_names(config["sources"])}
    known = ({n.lower() for n, _ in config["rows"]} | {n.lower() for n in config["own"]}
             | {n.lower() for n in config["common_words"]})
    unclassified = sorted(found - known)
    if unclassified:
        fail("names on this machine that nobody classified (add each to satellites.txt, "
             f"or to `own` or `common_words` in port.json): {unclassified}")


# ── build ───────────────────────────────────────────────────────────────────

def filter_history(repo, out, config, scratch):
    git(Path.cwd(), "clone", "--quiet", "--no-local", "--single-branch", "--branch",
        config["branch"], "--no-tags", str(repo), str(out))
    drops = scratch / "drop.txt"
    drops.write_text("".join(f"glob:{p}*\n" if p.endswith("/") else f"{p}\n" for p in config["drop"]))
    expressions = scratch / "expressions.txt"
    expressions.write_text("".join(f"regex:(?i){bounded(n)}==>{r}\n" for n, r in config["rows"]))
    mailmap = scratch / "mailmap"
    mailmap.write_text("\n".join(config["mailmap"]) + "\n")
    filter_repo = lambda *args: run(["git", "filter-repo", "--force", "--quiet", *args], cwd=out)
    filter_repo("--invert-paths", "--paths-from-file", str(drops))
    filter_repo("--path-rename", f"{TREE}:", "--replace-text", str(expressions),
                "--replace-message", str(expressions), "--mailmap", str(mailmap))
    for remote in git(out, "remote").split():
        git(out, "remote", "remove", remote)


def blobs(out):
    """Yield (sha, first path, content) for every file version in the history."""
    objects = git(out, "rev-list", "--all", "--objects").splitlines()
    first_path = {line[:40]: line[41:] for line in objects if len(line) > 41}
    batch = run(["git", "-C", str(out), "cat-file", "--batch"], data="\n".join(first_path).encode())
    position = 0
    while position < len(batch):
        header_end = batch.index(b"\n", position)
        sha, kind, size = batch[position:header_end].decode().split()
        position = header_end + 2 + int(size)
        if kind == "blob":
            yield sha, first_path[sha], batch[header_end + 1:position - 1]


def gate(out, config):
    """Every leak in the filtered history, as printable lines.

    A private name is a leak. A separator variant of one, or a common word in any
    case, is a leak until its line is reviewed: its id, a hash of the path (or
    `message`) and the line, goes in port.json `reviewed`."""
    names = [n for n, _ in config["rows"]]
    blocked, variants = name_pattern(names), variant_pattern(names)
    common = re.compile("|".join(map(bounded, config["common_words"])), re.I) if config["common_words"] else None
    reviewed, allow = set(config["reviewed"]), tuple(config["allow"])
    leaks = []

    def scan(where, scope, text):
        for number, line in enumerate(text.splitlines(), 1):
            if m := search(blocked, line):
                leaks.append(f"{where}:{number}: `{m[0]}`")
            elif m := search(variants, line) or search(common, line):
                key = hashlib.sha256(f"{scope}\n{line.strip()}".encode()).hexdigest()[:16]
                if key not in reviewed:
                    leaks.append(f"{where}:{number}: `{m[0]}` unreviewed (reviewed id {key}): {line.strip()[:120]}")

    log = git(out, "log", "--all", "--format=%H%x00%an <%ae>%x00%cn <%ce>%x00%B%x1e")
    for record in filter(str.strip, log.split("\x1e")):
        sha, author, committer, body = record.strip("\n").split("\x00", 3)
        for who in {author, committer} - set(config["authors"]):
            leaks.append(f"commit {sha[:12]}: identity `{who}` is not in port.json `authors`")
        scan(f"commit {sha[:12]} message", "message", body)
    for path in sorted(set(filter(None, git(out, "log", "--all", "--format=", "--name-only").splitlines()))):
        if not (path in allow or path.startswith(tuple(p for p in allow if p.endswith("/")))):
            leaks.append(f"path {path}: not under an allowed prefix")
        scan(f"path {path}", "path", path)
    for sha, path, content in blobs(out):
        if b"\0" in content and path not in config["binaries"]:
            leaks.append(f"blob {sha[:12]} ({path}): binary content the gate cannot read")
        else:
            scan(f"blob {sha[:12]} ({path})", path, content.decode("utf-8", errors="replace"))
    return leaks


def verification_list(out):
    text = (out / ".agents/AGENTS.md").read_text()
    block = re.search(r"## Verification.*?```sh\n(.*?)```", text, re.S)
    if not block:
        fail("the filtered .agents/AGENTS.md has no Verification list to run")
    return [line for line in block[1].splitlines() if line.strip() and not line.startswith("#")]


def verify(out):
    """Run the CI demo steps and the Verification list in the filtered checkout."""
    steps = ["python3 demo/embed-src.py", "python3 demo/check-inventory.py"] \
        if (out / "demo/embed-src.py").exists() else []
    steps += verification_list(out)
    if (out / ".agents/check-clean-tree.sh").exists():
        steps.append(".agents/check-clean-tree.sh")   # last, as in CI: no check may dirty the tree
    failed = []
    for step in steps:
        result = subprocess.run(["bash", "-c", step], cwd=out, capture_output=True, text=True)
        print(f"  {'ok  ' if result.returncode == 0 else 'FAIL'} {step}", flush=True)
        if result.returncode:
            failed.append(step)
            print("\n".join("      " + l for l in (result.stdout + result.stderr).splitlines()[-12:]))
    return failed


def compare(out, against, branch, head):
    """Report whether `head` fast-forwards what `against` already publishes."""
    if not git(out, "ls-remote", "--heads", against, branch).strip():
        print(f"port-public: {against} has no `{branch}` yet; this is the first publication")
        return
    git(out, "fetch", "--quiet", against, f"{branch}:refs/port/published")
    published = git(out, "rev-parse", "refs/port/published").strip()
    forward = subprocess.run(["git", "-C", str(out), "merge-base", "--is-ancestor",
                              published, head]).returncode == 0
    print(f"port-public: {'fast-forward' if forward else 'NOT a fast-forward'} from {published[:12]}"
          + ("" if forward else " — the published history differs; a leak fix means deleting and "
             "recreating the public repository, not a force-push"))


def build(repo, out, against):
    """Filter, gate, and verify in a scratch folder beside `out`; only a passing copy becomes `out`."""
    if git(repo, "status", "--porcelain"):
        fail("the working tree has uncommitted changes; the port reads committed history only")
    config = load_config(repo)
    if (current := git(repo, "branch", "--show-current").strip()) != config["branch"]:
        fail(f"HEAD is on `{current or 'a detached commit'}`; check out `{config['branch']}`, "
             "the branch the port replays, so the starters checked are the ones shipped")
    check(repo)
    classify(config)
    if out.exists() and any(out.iterdir()):
        fail(f"{out} is not empty")
    out.parent.mkdir(parents=True, exist_ok=True)
    # A killed build (SIGKILL, a crash) skips its cleanup and may leave an unfiltered clone here.
    for stale in out.parent.glob(f".{out.name}.partial-*"):
        shutil.rmtree(stale)
    work = Path(tempfile.mkdtemp(prefix=f".{out.name}.partial-", dir=out.parent))
    try:
        with tempfile.TemporaryDirectory(prefix="port-public-") as scratch:
            filter_history(repo, work / "copy", config, Path(scratch))
        leaks = gate(work / "copy", config)
        if leaks:
            print("\n".join(leaks), file=sys.stderr)
            fail(f"{len(leaks)} leak(s) in the filtered history; nothing was written to {out}")
        print(f"port-public: gate clean over {git(work / 'copy', 'rev-list', '--count', 'HEAD').strip()} commits",
              flush=True)
        if failed := verify(work / "copy"):
            fail(f"{len(failed)} check(s) fail on the filtered tree; nothing was written to {out}")
        if out.exists():
            out.rmdir()
        (work / "copy").rename(out)
    finally:
        shutil.rmtree(work)
    head = git(out, "rev-parse", "HEAD").strip()
    if against:
        compare(out, against, config["branch"], head)
    print(f"port-public: {out} holds {head[:12]}, ready for an approved push")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", type=Path, default=HERE, help="the private repository (default: this one)")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="generated starters match the tree")
    commands.add_parser("refresh", help="rewrite the generated starters")
    build_parser = commands.add_parser("build", help="filter history into OUT, gate it, verify it")
    build_parser.add_argument("out", type=Path)
    build_parser.add_argument("--against", help="the published repository to compare with")
    args = parser.parse_args()
    # SIGTERM becomes an exit, so `build` still removes its scratch copy of the private history.
    signal.signal(signal.SIGTERM, lambda *_: fail("terminated"))
    repo = args.repo.resolve()
    if args.command == "check":
        check(repo)
    elif args.command == "refresh":
        refresh(repo)
    else:
        build(repo, args.out.resolve(), args.against)


if __name__ == "__main__":
    main()

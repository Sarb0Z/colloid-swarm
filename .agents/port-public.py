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

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
PUBLIC = ".agents/public"
TREE = f"{PUBLIC}/tree/"
REPLACEMENT_SAFE = re.compile(r"^[A-Za-z0-9._/@-]+$")
WORDISH = re.compile(r"^[A-Za-z0-9_.-]+$")
DEBT_POINTER = re.compile(r"debt: ([a-z0-9][a-z0-9-]*)")
DEBT_HEADING = re.compile(r"^### ([a-z0-9][a-z0-9-]*)$", re.M)
DEBT_CITATION = re.compile(r"`([a-z0-9][a-z0-9-]*)`")
GENERATED = (".agents/debt-log.md", "demo/scaffold-showcase.html", "demo/scaffold-showcase.artifact.html")


def fail(message):
    raise SystemExit(f"port-public: {message}")


def git(repo, *args, text=True):
    return subprocess.run(["git", "-C", str(repo), *args], check=True,
                          capture_output=True, text=text).stdout


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


def name_pattern(names):
    """One case-insensitive regex: word-like names match whole words, paths match literally."""
    words = [re.escape(n) for n in names if WORDISH.match(n)]
    literals = [re.escape(n) for n in names if not WORDISH.match(n)]
    parts = []
    if words:
        parts.append(r"(?<![A-Za-z0-9_])(?:" + "|".join(sorted(words, key=len, reverse=True)) + r")(?![A-Za-z0-9_])")
    if literals:
        parts.append("(?:" + "|".join(literals) + ")")
    return re.compile("|".join(parts), re.I) if parts else None


# ── generated starters ──────────────────────────────────────────────────────

def dropped(rel, drops):
    """A drop entry ending in `/` removes a folder; any other removes that one file."""
    return any(rel == d or (d.endswith("/") and rel.startswith(d)) for d in drops)


def shipped_copy(repo, dest):
    """Copy the tracked working tree, minus dropped paths, with the starters laid over it."""
    config = load_config(repo)
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


def debt_starter(repo, shipped):
    """The debt log's header plus every entry shipped code points at, closed over citations."""
    text = (repo / ".agents/debt-log.md").read_text()
    starts = [m.start() for m in DEBT_HEADING.finditer(text)]
    header = text[:starts[0]] if starts else text
    sections = {DEBT_HEADING.match(text[s:])[1]: text[s:e].rstrip() + "\n"
                for s, e in zip(starts, starts[1:] + [len(text)])}
    wanted = set()
    for path in shipped.rglob("*"):
        if path.is_file() and not path.is_symlink() and path.suffix != ".html":
            wanted.update(DEBT_POINTER.findall(path.read_text(errors="replace")))
    wanted &= sections.keys()
    frontier = set(wanted)
    while frontier:
        cited = {i for w in frontier for i in DEBT_CITATION.findall(sections[w]) if i in sections}
        frontier = cited - wanted
        wanted |= frontier
    return header.rstrip() + "\n\n" + "\n".join(sections[w] for w in sections if w in wanted)


def generate(repo):
    """Return {path: text} for every generated starter."""
    out = {}
    with tempfile.TemporaryDirectory(prefix="port-public-") as scratch:
        shipped = Path(scratch)
        shipped_copy(repo, shipped)
        debt = shipped / ".agents/debt-log.md"
        if (repo / ".agents/debt-log.md").exists():
            out[".agents/debt-log.md"] = debt_starter(repo, shipped)
            debt.parent.mkdir(parents=True, exist_ok=True)
            debt.write_text(out[".agents/debt-log.md"])
        if (shipped / "demo/embed-src.py").exists():
            # embed-src.py rewrites the pages in place, so it starts from the private ones.
            for rel in GENERATED[1:]:
                shutil.copy2(repo / rel, shipped / rel)
            embed = subprocess.run([sys.executable, str(shipped / "demo/embed-src.py")],
                                   capture_output=True, text=True, cwd=shipped)
            if embed.returncode:
                fail(f"demo/embed-src.py failed on the public tree:\n{embed.stdout}{embed.stderr}")
            for rel in GENERATED[1:]:
                out[rel] = (shipped / rel).read_text()
    return out


def check(repo):
    if not (repo / PUBLIC / "port.json").exists():
        print(f"port-public: no {PUBLIC}/port.json; this repository ports nothing")
        return
    load_config(repo)
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

def machine_names(sources):
    """Names from the operator's machine, built without reading satellites.txt."""
    names = set()
    projects = Path(os.path.expanduser(sources["projects"]))
    for folder in sorted(p for p in projects.iterdir() if p.is_dir() and not p.name.startswith(".")):
        names.add(folder.name)
        for repo in [folder, *(p for p in folder.iterdir() if p.is_dir() and not p.name.startswith("."))]:
            if not (repo / ".git").exists():
                continue
            names.add(repo.name)
            remotes = subprocess.run(["git", "-C", str(repo), "remote", "-v"],
                                     capture_output=True, text=True).stdout
            for owner, name in re.findall(r"github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?\s", remotes):
                names.update((owner, name))
    identities = Path(os.path.expanduser(sources["identities"]))
    for identity in json.loads(identities.read_text())["identities"].values():
        names.update(identity["github_org"])
    registry = Path(os.path.expanduser(sources["registry"]))
    if registry.exists():
        names.update(re.findall(r"^\| \[([^\]]+)\]", registry.read_text(), re.M))
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
    expressions.write_text("".join(
        f"regex:(?i)(?<![A-Za-z0-9_]){re.escape(n)}(?![A-Za-z0-9_])==>{r}\n" if WORDISH.match(n)
        else f"{n}==>{r}\n" for n, r in config["rows"]))
    mailmap = scratch / "mailmap"
    mailmap.write_text("\n".join(config["mailmap"]) + "\n")
    run = lambda *args: subprocess.run(["git", "filter-repo", "--force", "--quiet", *args],
                                       cwd=out, check=True, capture_output=True)
    run("--invert-paths", "--paths-from-file", str(drops))
    run("--path-rename", f"{TREE}:", "--replace-text", str(expressions),
        "--replace-message", str(expressions), "--mailmap", str(mailmap))
    for remote in git(out, "remote").split():
        git(out, "remote", "remove", remote)


def gate(out, config):
    """Every leak in the filtered history, as printable lines."""
    blocked = name_pattern([n for n, _ in config["rows"]] + config.get("blocked_literals", []))
    common = re.compile(r"(?<![A-Za-z0-9_])(?:" + "|".join(map(re.escape, config["common_words"]))
                        + r")(?![A-Za-z0-9_])") if config["common_words"] else None
    reviewed, allow = set(config["reviewed"]), tuple(config["allow"])
    binaries, authors = set(config["binaries"]), set(config["authors"])
    leaks = []

    def scan(where, text):
        for number, line in enumerate(text.splitlines(), 1):
            if blocked and (m := blocked.search(line)):
                leaks.append(f"{where}:{number}: `{m[0]}`")
            if common and (m := common.search(line)):
                key = hashlib.sha256(line.strip().encode()).hexdigest()[:16]
                if key not in reviewed:
                    leaks.append(f"{where}:{number}: `{m[0]}` unreviewed (reviewed id {key}): {line.strip()[:120]}")

    log = git(out, "log", "--all", "--format=%H%x00%an <%ae>%x00%cn <%ce>%x00%B%x1e")
    for record in filter(str.strip, log.split("\x1e")):
        sha, author, committer, body = record.strip("\n").split("\x00", 3)
        for who in (author, committer):
            if who not in authors:
                leaks.append(f"commit {sha[:12]}: identity `{who}` is not in port.json `authors`")
        scan(f"commit {sha[:12]} message", body)
    paths = set(filter(None, git(out, "log", "--all", "--format=", "--name-only").splitlines()))
    for path in sorted(paths):
        if not (path in allow or path.startswith(tuple(p for p in allow if p.endswith("/")))):
            leaks.append(f"path {path}: not under an allowed prefix")
        scan(f"path {path}", path)
    objects = git(out, "rev-list", "--all", "--objects").splitlines()
    first_path = {line[:40]: line[41:] for line in objects if len(line) > 41}
    batch = subprocess.run(["git", "-C", str(out), "cat-file", "--batch"], check=True,
                           capture_output=True, input="\n".join(first_path).encode()).stdout
    position = 0
    while position < len(batch):
        header_end = batch.index(b"\n", position)
        sha, kind, size = batch[position:header_end].decode().split()
        content = batch[header_end + 1:header_end + 1 + int(size)]
        position = header_end + 2 + int(size)
        if kind != "blob":
            continue
        where = f"blob {sha[:12]} ({first_path[sha]})"
        if b"\0" in content and first_path[sha] not in binaries:
            leaks.append(f"{where}: binary content the gate cannot read")
            continue
        scan(where, content.decode("utf-8", errors="replace"))
    return leaks


def verification_list(out):
    text = (out / ".agents/AGENTS.md").read_text()
    block = re.search(r"## Verification.*?```sh\n(.*?)```", text, re.S)
    if not block:
        fail("the filtered .agents/AGENTS.md has no Verification list to run")
    return [line for line in block[1].splitlines() if line.strip() and not line.startswith("#")]


def verify(out):
    """Run the CI demo steps and the Verification list in the filtered checkout."""
    steps = []
    if (out / "demo/embed-src.py").exists():
        steps += ["python3 demo/embed-src.py", "python3 demo/check-inventory.py"]
    if (out / ".agents/check-clean-tree.sh").exists():
        steps.append(".agents/check-clean-tree.sh")
    failed = []
    for step in steps + verification_list(out):
        result = subprocess.run(["bash", "-c", step], cwd=out, capture_output=True, text=True)
        print(f"  {'ok  ' if result.returncode == 0 else 'FAIL'} {step}")
        if result.returncode:
            failed.append(step)
            print("\n".join("      " + l for l in (result.stdout + result.stderr).splitlines()[-12:]))
    return failed


def build(repo, out, against):
    if git(repo, "status", "--porcelain"):
        fail("the working tree has uncommitted changes; the port reads committed history only")
    config = load_config(repo)
    check(repo)
    classify(config)
    if out.exists() and any(out.iterdir()):
        fail(f"{out} is not empty")
    with tempfile.TemporaryDirectory(prefix="port-public-") as scratch:
        filter_history(repo, out, config, Path(scratch))
    leaks = gate(out, config)
    if leaks:
        print("\n".join(leaks), file=sys.stderr)
        fail(f"{len(leaks)} leak(s) in the filtered history; nothing here may be pushed")
    print(f"port-public: gate clean over {git(out, 'rev-list', '--count', 'HEAD').strip()} commits")
    failed = verify(out)
    if failed:
        fail(f"{len(failed)} check(s) fail on the filtered tree")
    head = git(out, "rev-parse", "HEAD").strip()
    if against:
        git(out, "fetch", "--quiet", against, f"{config['branch']}:refs/port/published")
        published = git(out, "rev-parse", "refs/port/published").strip()
        forward = subprocess.run(["git", "-C", str(out), "merge-base", "--is-ancestor",
                                  published, head]).returncode == 0
        print(f"port-public: {'fast-forward' if forward else 'NOT a fast-forward'} from {published[:12]}"
              + ("" if forward else " — the published history differs; a leak fix means deleting and "
                 "recreating the public repository, not a force-push"))
    print(f"port-public: {out} holds {head[:12]}, ready for an approved push")


def main(argv):
    repo = HERE
    if "--repo" in argv:
        index = argv.index("--repo")
        repo = Path(argv[index + 1]).resolve()
        del argv[index:index + 2]
    against = None
    if "--against" in argv:
        index = argv.index("--against")
        against = argv[index + 1]
        del argv[index:index + 2]
    if argv[:1] == ["check"] and len(argv) == 1:
        return check(repo)
    if argv[:1] == ["refresh"] and len(argv) == 1:
        return refresh(repo)
    if argv[:1] == ["build"] and len(argv) == 2:
        return build(repo, Path(argv[1]).resolve(), against)
    fail(__doc__.split("\n\n")[1])


if __name__ == "__main__":
    main(sys.argv[1:])

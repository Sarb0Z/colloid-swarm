#!/usr/bin/env python3
"""Three-way merge of a scaffold kit into a satellite that already carries one.

Usage:
  merge-kit.py --find-base <satellite>             run inside the carrier
  merge-kit.py <satellite> <base-kit> <new-kit> [--apply]

A satellite edits its copy of the scaffold, and a two-way copy of the new kit
erases those edits. The base kit is the export of the carrier commit the
satellite was last synced from; the difference between it and the new kit is
the carrier's change, and only that change is applied.

--find-base ranks carrier commits by how many scaffold files the satellite
holds byte-identical, and prints the best three. Build the base kit by running
that commit's own exporter from a detached worktree.

Without --apply the merge only reports. A file the satellite deleted stays
deleted: a pruned skill or stack pack is an adaptation, not drift. The root
AGENTS.md and CLAUDE.md are merged by section, by hand, so they are reported
and never written. Exit 1 when any path needs a hand merge.
"""

import filecmp
import os
import pathlib
import shutil
import subprocess
import sys

SCAFFOLD_ROOTS = (".agents", ".claude", ".codex", ".kimi", ".github/instructions",
                  ".github/lsp.json", ".github/copilot-instructions.md", ".worktreeinclude")
HAND_MERGED = {"AGENTS.md", "CLAUDE.md"}


def git(*args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True,
                          check=True).stdout


def blobs(repo, rev):
    out = git("ls-tree", "-r", rev, "--", *SCAFFOLD_ROOTS, cwd=repo)
    return {line.split("\t", 1)[1]: line.split()[2] for line in out.splitlines()}


def find_base(satellite):
    carrier = git("rev-parse", "--show-toplevel", cwd=os.getcwd()).strip()
    held = blobs(satellite, "HEAD")
    revisions = git("log", "--format=%h %ad %s", "--date=short", "--", *SCAFFOLD_ROOTS,
                    cwd=carrier).splitlines()
    ranked = []
    for line in revisions:
        tree = blobs(carrier, line.split()[0])
        ranked.append((sum(1 for p, b in held.items() if tree.get(p) == b), line))
    ranked.sort(key=lambda item: item[0], reverse=True)
    print(f"{len(held)} scaffold files in {satellite}; identical-file count per carrier commit:")
    for same, line in ranked[:3]:
        print(f"  {same:4d}  {line}")


def files(root):
    """Map each file and link to its path. A linked directory is one entry:
    descending into it would write through the link into its target."""
    found = {}
    for directory, subdirectories, names in os.walk(root, followlinks=False):
        here = pathlib.Path(directory)
        linked = [d for d in subdirectories if (here / d).is_symlink()]
        for name in names + linked:
            relative = (here / name).relative_to(root).as_posix()
            if not relative.startswith("export/"):
                found[relative] = here / name
    return found


def same(a, b):
    if a.is_symlink() or b.is_symlink():
        return a.is_symlink() and b.is_symlink() and os.readlink(a) == os.readlink(b)
    if a.is_dir() or b.is_dir():
        return False                                      # a real directory where a link was
    return filecmp.cmp(a, b, shallow=False)


def place(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink() or destination.exists():
        destination.unlink()
    if source.is_symlink():
        destination.symlink_to(os.readlink(source))
    else:
        shutil.copy2(source, destination)


def text_merge(ours, base, theirs):
    """Return (merged text, conflicted), or None when a side is not text."""
    if any(p.is_symlink() or p.is_dir() for p in (ours, base, theirs)):
        return None
    try:
        for p in (ours, base, theirs):
            p.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return None
    run = subprocess.run(["git", "merge-file", "-p", "-L", "satellite", "-L", "base-kit",
                          "-L", "new-kit", str(ours), str(base), str(theirs)],
                         capture_output=True, text=True)
    if run.returncode < 0 or run.returncode > 127:
        raise SystemExit(f"merge-kit: git merge-file failed on {ours}: {run.stderr}")
    return run.stdout, run.returncode > 0


def merge(satellite, base_kit, new_kit, apply):
    base, new = files(base_kit), files(new_kit)
    report = {key: [] for key in ("added", "updated", "merged", "removed",
                                  "kept-deleted", "hand-merge", "conflict")}
    for relative in sorted(set(base) | set(new)):
        ours = satellite / relative
        present = ours.is_symlink() or ours.exists()
        b, n = base.get(relative), new.get(relative)
        if relative in HAND_MERGED:
            if not (b and n and same(b, n)):
                report["hand-merge"].append(relative)
            continue
        if n and not b:                                   # the carrier added it
            if not present:
                report["added"].append(relative)
                if apply:
                    place(n, ours)
            elif not same(ours, n):
                report["conflict"].append(f"{relative}  (satellite has its own file here)")
            continue
        if b and not n:                                   # the carrier removed it
            if present and same(ours, b):
                report["removed"].append(relative)
                if apply:
                    ours.unlink()
            elif present:
                report["conflict"].append(f"{relative}  (carrier removed it; satellite edited it)")
            continue
        if same(b, n):
            continue                                      # no carrier change
        if not present:
            report["kept-deleted"].append(relative)
            continue
        if same(ours, n):
            continue
        if same(ours, b):
            report["updated"].append(relative)
            if apply:
                place(n, ours)
            continue
        merged = text_merge(ours, b, n)
        if merged is None:
            report["conflict"].append(f"{relative}  (link, directory or binary changed on both sides)")
            continue
        text, conflicted = merged
        report["conflict" if conflicted else "merged"].append(relative)
        if apply:
            mode = ours.stat().st_mode
            ours.write_text(text, encoding="utf-8")
            os.chmod(ours, mode | (n.stat().st_mode & 0o111))
    for key, paths in report.items():
        if paths:
            print(f"{key}: {len(paths)}")
            for path in paths:
                print(f"  {path}")
    if not apply:
        print("dry run: nothing written; rerun with --apply")
    return 1 if report["conflict"] or report["hand-merge"] else 0


def main(argv):
    if len(argv) == 2 and argv[0] == "--find-base":
        find_base(pathlib.Path(argv[1]).resolve())
        return 0
    apply = "--apply" in argv
    positional = [a for a in argv if a != "--apply"]
    if len(positional) != 3 or any(a.startswith("-") for a in positional):
        raise SystemExit(__doc__.strip().split("\n\n")[0])
    satellite, base_kit, new_kit = (pathlib.Path(a).resolve() for a in positional)
    for kit in (base_kit, new_kit):
        if not (kit / ".agents").is_dir():
            raise SystemExit(f"merge-kit: {kit} is not an exported kit")
    return merge(satellite, base_kit, new_kit, apply)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

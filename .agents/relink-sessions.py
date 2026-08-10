#!/usr/bin/env python3
"""Reattach Claude Code session history after a project directory moves.

Claude Code files transcripts under `~/.claude/projects/<slug>/`, where the slug
is the project's absolute working directory with its separators folded to `-`.
The slug is derived from the path, never stored against the project, so moving
or renaming a checkout points Claude at a fresh empty folder and the history
reads as lost. It is not: the transcripts sit under the old slug, orphaned.

Reattaching them is a copy plus a rewrite. The copy alone is not enough, because
every transcript records absolute paths -- the per-entry `cwd` that `/resume`
restores into, and the path of each file the session touched -- all still naming
the old location. Left stale on a case-insensitive filesystem they do not merely
dangle, they resolve somewhere wrong, so the rewrite is the point and the copy
is the easy half.

Usage:
    .agents/relink-sessions.py <old-project-path> <new-project-path> [--apply]

Dry run by default; `--apply` writes. The source folder is left in place, so a
bad rewrite costs nothing -- delete it once `/resume` in the new location looks
right, or pass `--prune` to have a successful run do it.
"""

import argparse
import pathlib
import re
import shutil

PROJECTS = pathlib.Path("~/.claude/projects").expanduser()

# How Claude Code encodes a path as a folder name: separators and dots fold to
# hyphens. Derived rather than recorded, which is the whole reason a moved
# project loses sight of its own history.
SLUG_CHARS = re.compile(r"[/.]")

# A path reference ends where a path cannot continue. Without this guard,
# rewriting `/Projects/parchi` would also maul `/Projects/parchi-legacy`, which
# is a different project that did not move.
BOUNDARY = r"""(?=[/"\s\\'`),:;\]}]|$)"""


def slug(path):
    return SLUG_CHARS.sub("-", str(pathlib.Path(path).expanduser().resolve(strict=False)))


def source_folder(path):
    """Locate the orphaned folder, naming near-misses when the guess is wrong.

    The slug encoding is inferred from observed folder names rather than read
    from Claude Code, so a miss is more likely to be this script's rule falling
    short than a genuinely absent history. Suggesting neighbours turns that from
    a dead end into a one-word correction.
    """
    folder = PROJECTS / slug(path)
    if folder.is_dir():
        return folder
    stem = pathlib.Path(path).name.lower()
    near = sorted(d.name for d in PROJECTS.iterdir() if d.is_dir() and stem in d.name.lower())
    hint = f"\n  Did you mean one of: {near}" if near else ""
    raise SystemExit(f"relink: no transcript folder for {path}\n  Looked for: {folder}{hint}")


def transcripts(folder):
    """Every transcript under a project folder, subagent runs included.

    Subagents live one level down beside the parent session they belong to; a
    parent restored without them resumes with holes where its delegated work was.
    """
    return sorted(folder.rglob("*.jsonl"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("old_path", help="where the project used to live")
    parser.add_argument("new_path", help="where it lives now")
    parser.add_argument("--apply", action="store_true", help="write changes (default: dry run)")
    parser.add_argument("--prune", action="store_true", help="delete the source folder afterwards")
    args = parser.parse_args()

    source = source_folder(args.old_path)
    target = PROJECTS / slug(args.new_path)
    if source == target:
        raise SystemExit("relink: both paths encode to the same folder, nothing to do")

    old = str(pathlib.Path(args.old_path).expanduser().resolve(strict=False))
    new = str(pathlib.Path(args.new_path).expanduser().resolve(strict=False))
    if old.lower() == new.lower():
        # Same directory under a case-insensitive filesystem. The slugs still
        # differ, so the history is genuinely orphaned and worth moving, but
        # rewriting paths that already resolve correctly only risks damage.
        print("relink: paths differ only by case -- copying without rewrite\n")
        old = None

    stale = re.compile(re.escape(old) + BOUNDARY) if old else None
    print(f"[{'APPLY' if args.apply else 'DRY RUN'}] {source}\n{'':10}-> {target}\n")

    copied = skipped = 0
    for path in transcripts(source):
        relative = path.relative_to(source)
        destination = target / relative

        # A transcript already sitting in the target is a session that genuinely
        # ran there. Same-named or not, it is not this one's to overwrite.
        if destination.exists():
            print(f"  skip  {relative}  (already present)")
            skipped += 1
            continue

        text = path.read_text(errors="ignore")
        text, rewrites = stale.subn(new, text) if stale else (text, 0)
        print(f"  copy  {relative}  ({rewrites} path references rewritten)")
        copied += 1
        if args.apply:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(text)
            # `/resume` orders sessions by mtime, so a copy that stamps itself
            # with today's date files the whole history under one timestamp.
            shutil.copystat(path, destination)

    print(f"\n{copied} copied, {skipped} skipped.")
    if not args.apply:
        print("Dry run -- re-run with --apply to write.")
    elif args.prune and not skipped:
        shutil.rmtree(source)
        print(f"Pruned {source}")
    elif args.prune:
        print(f"Kept {source}: some transcripts were skipped, so it is not fully copied.")


if __name__ == "__main__":
    main()

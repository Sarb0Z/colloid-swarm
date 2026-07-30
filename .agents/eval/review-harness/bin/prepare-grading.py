#!/usr/bin/env python3
"""Anonymise one fixture's reports into a grading directory.

The grader must not learn which arm wrote which report. Filenames are opaque
and the order is a seeded shuffle, so the mapping is reproducible here and
unavailable there.
"""
import os
import random
import shutil
import sys
from pathlib import Path

SEED = 20260728
HERE = Path(__file__).resolve().parent.parent


def work_root():
    base = os.environ.get("REVIEW_HARNESS_WORK")
    if base:
        return Path(base)
    return Path(os.environ.get("TMPDIR", "/tmp")) / "rvw"


def runs_for(root, fixture):
    """Read index.tsv. Run directories are opaque, so the map lives outside."""
    out = []
    for line in (root / "index.tsv").read_text().splitlines()[1:]:
        token, fx, rep = line.split("\t")
        if fx == fixture:
            out.append((token, rep))
    return sorted(out)


def main():
    fixture = sys.argv[1]
    root = work_root()
    runs = [(t, r) for t, r in runs_for(root, fixture)
            if (root / "runs" / t / "report.md").exists()
            and (root / "runs" / t / "report.md").stat().st_size > 0]
    if not runs:
        sys.exit(f"no non-empty reports for {fixture}")

    grading = root / "grading" / fixture
    shutil.rmtree(grading, ignore_errors=True)
    (grading / "reviews").mkdir(parents=True)

    order = list(runs)
    random.Random(SEED).shuffle(order)

    key = []
    for i, (token, rep) in enumerate(order, 1):
        label = f"review-{i:02d}"
        shutil.copy(root / "runs" / token / "report.md",
                    grading / "reviews" / f"{label}.md")
        key.append(f"{label}\t{rep}\t{token}\n")
    (grading / "key.tsv").write_text("".join(key))

    shutil.copy(HERE / "ref" / f"{fixture}.md", grading / "REFERENCE.md")
    tree = root / "runs" / order[0][0] / "tree"
    for name in ("CHANGE.diff", "REVIEW-INTENT.md"):
        shutil.copy(tree / name, grading / name)
    shutil.copy(HERE / "grader-task.md", grading / "TASK.md")

    print(f"grading dir: {grading}")
    print(f"reviews:     {len(order)}")
    print(f"output to:   {grading / 'grades.tsv'}")


if __name__ == "__main__":
    main()

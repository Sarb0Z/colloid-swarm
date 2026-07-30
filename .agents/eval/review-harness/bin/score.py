#!/usr/bin/env python3
"""Collate grader output into per-run metrics plus a conformance check.

Recall counts reachable reference findings only. Reachability comes from the
fixture annotation, corrected by ref/reach-overrides.tsv where the base tree
supplies a file the fixture lacked.
"""
import os
import re
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent


def work_root():
    base = os.environ.get("REVIEW_HARNESS_WORK")
    if base:
        return Path(base)
    return Path(os.environ.get("TMPDIR", "/tmp")) / "rvw"


def load_reach(fixture):
    reach = {}
    path = HERE / "ref" / f"{fixture}.reach.tsv"
    for line in path.read_text().splitlines():
        rid, ok, *_ = line.split("\t")
        reach[rid] = ok == "yes"
    ov = HERE / "ref" / "reach-overrides.tsv"
    if ov.exists():
        for line in ov.read_text().splitlines()[1:]:
            fx, rid, ok, _reason = line.split("\t", 3)
            if fx == fixture:
                reach[rid] = ok == "yes"
    return reach


def parse_grades(text):
    matches, coverage, section = [], [], 1
    for line in text.splitlines():
        line = line.rstrip("\n")
        if line.startswith("## COVERAGE"):
            section = 2
            continue
        if not line.strip() or line.startswith("review\t"):
            continue
        cols = line.split("\t")
        if section == 1 and len(cols) >= 3:
            matches.append((cols[0].strip(), cols[1].strip(), cols[2].strip()))
        elif section == 2 and len(cols) >= 3:
            coverage.append((cols[0].strip(), cols[1].strip(), cols[2].strip()))
    return matches, coverage


def norm(label):
    return re.sub(r"\.md$", "", label.strip())


def main():
    fixture = sys.argv[1]
    root = work_root()
    grading = root / "grading" / fixture

    key = {}
    for line in (grading / "key.tsv").read_text().splitlines():
        label, rep, token = line.split("\t")
        key[label] = (rep, token)

    reach = load_reach(fixture)
    reachable = {r for r, ok in reach.items() if ok}
    matches, coverage = parse_grades((grading / "grades.tsv").read_text())

    runs = {}
    for label, (rep, token) in key.items():
        runs[label] = {"rep": rep, "token": token,
                       "total": 0, "matched": 0, "covered": set(), "ranks": []}

    for label, pos, rid in matches:
        r = runs.get(norm(label))
        if r is None:
            continue
        r["total"] += 1
        if rid.startswith("R"):
            r["matched"] += 1
            if rid in reachable:
                try:
                    r["ranks"].append((rid, int(pos)))
                except ValueError:
                    pass

    for label, rid, covered in coverage:
        r = runs.get(norm(label))
        if r is not None and covered.lower() == "yes" and rid in reachable:
            r["covered"].add(rid)

    # The conformance line is what the contract makes mandatory, so it is the
    # one column worth checking on every run. Look only at the opening of the
    # report: a conformance claim buried at the end is the defect, not a pass.
    for label, r in runs.items():
        src = root / "runs" / r["token"] / "report.md"
        head = " ".join(src.read_text().split()[:200]).lower() if src.exists() else ""
        r["conformance"] = any(
            k in head for k in ("does what", "does the code", "conformance",
                                "core question", "correctness of", "as intended",
                                "does not do", "intent requires"))

    denom = len(reachable)
    print(f"# {fixture} — {denom} reachable of {len(reach)} reference findings\n")
    print("run\trep\trecall\ttotal\tmatched\tunmatched%\tconformance")
    for label in sorted(runs, key=lambda k: runs[k]["rep"]):
        r = runs[label]
        unm = 100 * (r["total"] - r["matched"]) / r["total"] if r["total"] else 0
        print(f"{label}\t{r['rep']}\t{len(r['covered'])}/{denom}"
              f"\t{r['total']}\t{r['matched']}\t{unm:.0f}%"
              f"\t{'y' if r['conformance'] else 'n'}")

    counts = [len(r["covered"]) for r in runs.values()]
    union = set().union(*[r["covered"] for r in runs.values()]) if runs else set()
    conf = sum(1 for r in runs.values() if r["conformance"])
    print(f"\nruns\t{len(runs)}")
    print(f"mean_recall\t{statistics.mean(counts):.2f}/{denom}")
    print(f"spread\t{min(counts)}-{max(counts)}")
    print(f"union_recall\t{len(union)}/{denom}")
    print(f"conformance_stated\t{conf}/{len(runs)}")


if __name__ == "__main__":
    main()

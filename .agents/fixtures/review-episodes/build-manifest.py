#!/usr/bin/env python3
"""Generate manifest.tsv from the ground-truth files.

Ground truths are prose evidence in two shapes (`CLASS:` bare or
`**CLASS:**` bulleted). This reads both and emits one machine-readable
row per finding for A/B scoring scripts.

Run: python3 .agents/fixtures/review-episodes/build-manifest.py
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).parent
HEADING = re.compile(r"^## (\d+)\.\s*(.+)$", re.M)
CLASS = re.compile(r"\*{0,2}CLASS:\*{0,2}\s*(REQUIREMENT|QUALITY|AMBIGUITY)")
DISP = re.compile(r"\*{0,2}DISPOSITION:\*{0,2}\s*(ADOPTED|DECLINED|ESCALATED|IGNORED)")
UNREACHED = re.compile(r"REACHABILITY:\s*NOT|NOT RECOVERED", re.I)

rows = []
for gt in sorted(ROOT.glob("*/ground-truth.md")):
    text = gt.read_text(encoding="utf-8")
    marks = list(HEADING.finditer(text))
    for i, m in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(text)
        block = text[m.start():end]
        cls = CLASS.search(block)
        disp = DISP.search(block)
        rows.append((
            gt.parent.name,
            m.group(1),
            cls.group(1) if cls else "UNLABELED",
            disp.group(1) if disp else "UNLABELED",
            "no" if UNREACHED.search(block) else "yes",
            m.group(2).strip()[:70],
        ))

out = ROOT / "manifest.tsv"
with out.open("w", encoding="utf-8") as f:
    f.write("fixture\tid\tclass\tdisposition\treachable\tsummary\n")
    for r in rows:
        f.write("\t".join(r) + "\n")
print(f"{len(rows)} findings -> {out.relative_to(ROOT.parent.parent.parent)}")

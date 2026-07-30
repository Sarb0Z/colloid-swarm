#!/usr/bin/env python3
"""Strip a ground-truth file into a grader reference.

The grader matches findings. It must not see how the original lead judged
them, or a match becomes a judgement. Keep the title and the finding prose;
drop class, disposition, severity, reachability, and evidence.

The corpus uses two ground-truth layouts: bulleted metadata (`- **CLASS:**`)
and bare metadata (`CLASS:`). Both terminate a finding body.
"""
import re
import sys
from pathlib import Path

BANNED = re.compile(
    r"\b(CLASS|DISPOSITION|ADOPTED|DECLINED|ESCALATED|IGNORED|REQUIREMENT"
    r"|QUALITY|AMBIGUITY|Evidence|REACHABILITY|HIGH|MEDIUM|LOW|MINOR"
    r"|should-fix|nice-to-have)\b"
)
HEADING = re.compile(r"^## (\d+)\.\s+(.*)$")
OTHER_HEADING = re.compile(r"^#{1,3} ")
FINDING = re.compile(r"^\s*\*{0,2}FINDING\b[^:]*:\s*\*{0,2}\s*(.*)$", re.I)
SEVERITY = re.compile(r"^\((?:HIGH|MEDIUM|LOW|LOW-MED|MED|MINOR)[^)]*\)\s*")
META = re.compile(
    r"^\s*(?:-\s*)?(?:\*\*)?(CLASS|DISPOSITION|REACHABILITY|Evidence"
    r"|DISPOSITION NOTE|NOTE)\b"
)
# Precedes the finding prose, so it is dropped without ending the body.
SKIP = re.compile(r"^\s*(?:-\s*)?(?:\*\*)?ROUND\b", re.I)
REACH = re.compile(r"^\s*(?:-\s*)?(?:\*\*)?REACHABILITY:?\*{0,2}:?\s*(.*)$")


def parse(text):
    out, cur = [], None
    for line in text.splitlines():
        h = HEADING.match(line)
        if h:
            cur = {"n": int(h.group(1)),
                   "title": SEVERITY.sub("", h.group(2).strip()),
                   "body": [], "reach": "", "done": False}
            out.append(cur)
            continue
        if cur is None:
            continue
        if OTHER_HEADING.match(line):
            cur = None
            continue
        if SKIP.match(line):
            continue
        r = REACH.match(line)
        if r:
            cur["reach"] = r.group(1).strip()
            cur["done"] = True
            continue
        if META.match(line) or line.startswith("---"):
            cur["done"] = True
            continue
        if cur["done"]:
            continue
        f = FINDING.match(line)
        cur["body"].append(f.group(1) if f else line)
    return out


def main():
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    findings = parse(src.read_text())
    if not findings:
        sys.exit(f"no findings parsed from {src}")

    parts = ["# Reference findings",
             "Each entry is one previously-reported finding on this artifact.", ""]
    for f in findings:
        body = " ".join(" ".join(f["body"]).split())
        if not body:
            sys.exit(f"R{f['n']} in {src} parsed with an empty body")
        parts += [f"## R{f['n']}", f["title"], "", body, ""]
    text = "\n".join(parts)

    leaks = sorted(set(BANNED.findall(text)))
    if leaks:
        sys.exit(f"reference leaks judgement vocabulary: {leaks}")

    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(text)

    reach = dst.with_suffix(".reach.tsv")
    reach.write_text("".join(
        f"R{f['n']}\t{'no' if f['reach'].lower().startswith('not') else 'yes'}"
        f"\t{f['reach']}\n" for f in findings))

    n_reach = sum(1 for f in findings if not f["reach"].lower().startswith("not"))
    print(f"{dst}: {len(findings)} entries ({n_reach} reachable), leak-check clean")


if __name__ == "__main__":
    main()

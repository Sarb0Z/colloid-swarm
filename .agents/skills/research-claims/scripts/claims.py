#!/usr/bin/env python3
"""Check a claims ledger against saved sources, and lint report prose for typed-in numbers.

Usage:
    python3 -I claims.py check <claims.csv> --sources <folder>
    python3 -I claims.py prose <file> [<file> ...]

`check` reads a ledger of `key,source,values,quote` rows. A row passes when its
quote is in the saved text of its source and each numeral in `values`
(separated by `|`) is in the quote as a whole number: `1.0` is not in `11.0`,
and `5` is not in `5%`. Every problem is printed with its row, and the exit
code is 1 when there is one.

`prose` reads Markdown, R Markdown or Quarto and reports each decimal number,
percentage and thousands-separated number left in the prose, that is, outside
code, inline code, math, links and citation keys. Integers are not read: a count
is for a reviewer to trace, and so is a percentage that names an interval's level
("95% CI"). A comment `<!-- literal: <reason> -->` on a line allows the numbers
on it; a comment with no reason is itself a finding.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from source_text import SourceProblem, normalize, source_file, source_text  # noqa: E402

COLUMNS = ("key", "source", "values", "quote")


def numeral(text: str) -> re.Pattern[str]:
    """`text` as a whole numeral: not inside a longer number, and not the number of a percentage."""
    return re.compile(rf"(?<!\d)(?<!\d\.){re.escape(text)}(?!\d|\.\d|\s*%)")


def check_claims(rows: list[dict[str, str]], first_line: int, sources: Path) -> tuple[list[str], int]:
    """(problems, number of distinct sources read) for the ledger's rows, the first on `first_line`."""
    problems: list[str] = []
    texts: dict[str, str | None] = {}
    seen: dict[str, int] = {}
    for line, row in enumerate(rows, start=first_line):
        key, source = row["key"].strip(), row["source"].strip()
        where = f"line {line}, key {key!r}"
        if key in seen:
            problems.append(f"{where}: key {key!r} is used twice (lines {seen[key]} and {line})")
        seen.setdefault(key, line)
        quote = normalize(row["quote"])
        if not quote:
            problems.append(f"{where}: no quote")
            continue
        if source not in texts:
            try:
                texts[source] = source_text(source_file(sources, source))
            except SourceProblem as error:
                texts[source] = None
                problems.append(f"{where}: {error}")
        text = texts[source]
        if text is None:
            continue
        if quote not in text:
            problems.append(f"{where}: quote not in the text of {source}: {row['quote'].strip()!r}")
            continue
        for value in (part.strip() for part in row["values"].split("|") if part.strip()):
            if not numeral(value).search(quote):
                problems.append(f"{where}: {value} not in the quote")
    return problems, sum(1 for text in texts.values() if text is not None)


def read_ledger(path: Path) -> tuple[list[dict[str, str]], list[str]]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        missing = [name for name in COLUMNS if name not in (reader.fieldnames or [])]
        if missing:
            return [], [f"{path.name}: missing column(s) {', '.join(missing)}; a ledger row is key,source,values,quote"]
        return [{name: (row.get(name) or "") for name in COLUMNS} for row in reader], []


def run_check(args: argparse.Namespace) -> int:
    rows, problems = read_ledger(args.ledger)
    if not problems:
        problems, used = check_claims(rows, 2, args.sources)
    else:
        used = 0
    for problem in problems:
        print(f"{args.ledger.name} {problem}")
    if problems:
        print(f"{len(problems)} problem(s) in {len(rows)} statement(s)")
        return 1
    print(f"{args.ledger.name}: {len(rows)} statements found in {used} saved sources")
    return 0


# Text that is not prose: inline code, math, links' targets and citation keys.
INLINE_CODE = re.compile(r"(`+)[^`]*?\1")
MATH = re.compile(r"\$\$.*?\$\$|\$[^$\n]+\$")
LINK_TARGET = re.compile(r"\]\([^)]*\)")
CITATION = re.compile(r"\[@[^\]]*\]|@[\w:.-]+")
URL = re.compile(r"https?://\S+")
COMMENT = re.compile(r"<!--.*?-->")
LITERAL = re.compile(r"<!--\s*literal\s*(?::\s*(.*?))?\s*-->")
NUMBER = re.compile(r"(?<![\w.,])(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+\.\d+|\d+(?:\.\d+)?%)(?!\w)")
REFERENCE_WORD = re.compile(r"(?:Figure|Fig\.|Table|Section|Sec\.|Appendix|Equation|Eq\.|§)\s*$")
# A percentage that names an interval's level ("95% CI") is a method setting, not a result.
LEVEL_WORD = re.compile(r"\s*(?:CI\b|confidence|credible|prediction|interval)")


def prose_findings(path: Path) -> list[tuple[int, str]]:
    """(line, finding) for each typed-in number left in the prose of one file."""
    lines = path.read_text(encoding="utf-8").splitlines()
    findings: list[tuple[int, str]] = []
    in_front_matter = bool(lines) and lines[0].strip() == "---"
    fence = ""
    in_math_block = False
    for number, line in enumerate(lines, start=1):
        stripped = line.strip()
        if in_front_matter:
            if number > 1 and stripped in ("---", "..."):
                in_front_matter = False
            continue
        marker = re.match(r"(`{3,}|~{3,})", stripped)
        if marker:
            fence = "" if fence and stripped.startswith(fence[0] * len(fence)) else (fence or marker.group(1))
            continue
        if fence:
            continue
        if stripped.count("$$") == 1:
            in_math_block = not in_math_block
            continue
        if in_math_block:
            continue
        literal = LITERAL.search(line)
        if literal:
            if not (literal.group(1) or "").strip():
                findings.append((number, "literal needs a reason"))
            continue
        text = COMMENT.sub(" ", line)
        for pattern in (INLINE_CODE, MATH, URL, LINK_TARGET, CITATION):
            text = pattern.sub(" ", text)
        for match in NUMBER.finditer(text):
            if REFERENCE_WORD.search(text[:match.start()]) or LEVEL_WORD.match(text, match.end()):
                continue
            findings.append((number, match.group(1)))
    return findings


def run_prose(args: argparse.Namespace) -> int:
    total = 0
    for path in args.files:
        findings = prose_findings(path)
        for number, finding in findings:
            print(f"{path}:{number}: {finding}")
        if findings:
            total += len(findings)
        else:
            print(f"{path}: no typed-in decimals or percentages in prose")
    if total:
        print(f"{total} finding(s): compute each number from a results file with inline code, or allow its line with <!-- literal: <reason> -->")
        return 1
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check", help="quotes in saved sources, numerals in quotes")
    check.add_argument("ledger", type=Path)
    check.add_argument("--sources", type=Path, required=True, help="the folder of saved sources")
    check.set_defaults(func=run_check)
    prose = sub.add_parser("prose", help="typed-in decimals and percentages in report prose")
    prose.add_argument("files", type=Path, nargs="+")
    prose.set_defaults(func=run_prose)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

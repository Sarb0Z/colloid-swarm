#!/usr/bin/env python3
"""Gate `claims.py`: a quote must be in its saved source, and prose must not carry typed-in numbers.

The cases build small saved sources and ledgers in a scratch folder and run the
real command line, the way a lead runs it. They fail if a quote that is not in
its source passes, if a number that is only part of a longer number passes, if a
folder holding two text files is read by guessing, if a source name can reach
outside the sources folder, or if `prose` lets a typed-in decimal or percentage
through. Every expected value is a literal written here, not a recomputation.
"""

import csv
import re
import subprocess
import sys
import tempfile
from pathlib import Path

CLAIMS = Path(__file__).resolve().parent / "claims.py"
failures: list[str] = []


def check(condition: bool, what: str) -> None:
    if not condition:
        failures.append(what)
        print(f"FAIL: {what}", file=sys.stderr)
    else:
        print(f"ok: {what}")


def ledger(path: Path, rows: list[tuple[str, ...]], header: tuple[str, ...] = ("key", "source", "values", "quote")) -> Path:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(header)
        writer.writerows(rows)
    return path


def run(*args: str, cwd: Path, isolated: bool = False) -> subprocess.CompletedProcess:
    command = [sys.executable, *(["-I"] if isolated else []), str(CLAIMS), *args]
    return subprocess.run(command, capture_output=True, text=True, cwd=cwd)


with tempfile.TemporaryDirectory() as scratch_name:
    scratch = Path(scratch_name).resolve()
    sources = scratch / "sources"
    for folder in ("md1", "html1", "xml1", "json1", "both", "pdfonly"):
        (sources / folder).mkdir(parents=True)
    (sources / "md1/fulltext.md").write_text("The risk ratio was 1.17 (95% CI 0.57 to 2.37) in 12 trials. Dose 11.0 mg. Event rate 5%.\n", encoding="utf-8")
    (sources / "html1/page.html").write_text(
        '<html><body><script>var x = "hidden quote";</script>'
        "<p>Major bleeding occurred in 4.9%  of patients — and 2.0% of controls.</p></body></html>", encoding="utf-8")
    (sources / "xml1/article.xml").write_text("<article><abstract><p>Mean age was <b>63.2</b> years.</p></abstract></article>", encoding="utf-8")
    (sources / "json1/record.json").write_text('{"title": "A trial", "abstractText": "Death occurred in 3 of 168 patients."}', encoding="utf-8")
    (sources / "both/fulltext.md").write_text("one", encoding="utf-8")
    (sources / "both/article.xml").write_text("<a>two</a>", encoding="utf-8")
    (sources / "pdfonly/paper.pdf").write_bytes(b"%PDF-1.4")
    (sources / "loose.md").write_text("A loose file holds 7 patients.", encoding="utf-8")

    good = ledger(scratch / "good.csv", [
        ("rr", "md1", "1.17|0.57|2.37", "The risk ratio was 1.17 (95% CI 0.57 to 2.37)"),
        ("bleed", "html1", "4.9%|2.0%", "Major bleeding occurred in 4.9% of patients - and 2.0% of controls."),
        ("age", "xml1", "63.2", "Mean age was 63.2 years."),
        ("death", "json1", "3|168", "Death occurred in 3 of 168 patients."),
        ("loose", "loose.md", "7", "holds 7 patients"),
    ])
    passed = run("check", str(good), "--sources", str(sources), cwd=scratch)
    check(passed.returncode == 0 and "5 statements found in 5 saved sources" in passed.stdout,
          f"a ledger whose quotes are all in their sources passes: {passed.stdout.strip()} {passed.stderr.strip()}")

    bad_quote = ledger(scratch / "quote.csv", [("rr", "md1", "1.18", "The risk ratio was 1.18 (95% CI 0.57 to 2.37)")])
    missing_quote = run("check", str(bad_quote), "--sources", str(sources), cwd=scratch)
    check(missing_quote.returncode == 1 and "rr" in missing_quote.stdout and "quote not in the text of md1" in missing_quote.stdout,
          f"a changed quote fails and names its key and source: {missing_quote.stdout.strip()}")

    boundaries = ledger(scratch / "bounds.csv", [
        ("inner", "md1", "1.0", "Dose 11.0 mg."),
        ("whole", "md1", "11.0", "Dose 11.0 mg."),
        ("percent", "md1", "5", "Event rate 5%."),
        ("percent-ok", "md1", "5%", "Event rate 5%."),
        ("absent", "md1", "9", "Dose 11.0 mg."),
    ])
    bounded = run("check", str(boundaries), "--sources", str(sources), cwd=scratch)
    problem_lines = [line for line in bounded.stdout.splitlines() if "not in the quote" in line]
    joined = " ".join(problem_lines)
    check(bounded.returncode == 1 and len(problem_lines) == 3
          and all(key in joined for key in ("'inner'", "'percent'", "'absent'")) and "'whole'" not in joined and "'percent-ok'" not in joined,
          f"a value that is part of a longer number, or of a percentage, is not in the quote: {problem_lines}")

    structure = ledger(scratch / "structure.csv", [
        ("twin", "md1", "", "Dose 11.0 mg."),
        ("twin", "md1", "", "Dose 11.0 mg."),
        ("empty", "md1", "", ""),
        ("both", "both", "", "one"),
        ("pdf", "pdfonly", "", "x"),
        ("gone", "nowhere", "", "x"),
        ("escape", "../outside", "", "x"),
    ])
    shaped = run("check", str(structure), "--sources", str(sources), cwd=scratch)
    out = shaped.stdout
    check(shaped.returncode == 1 and "key 'twin' is used twice" in out and "empty" in out and "no quote" in out,
          f"a repeated key and an empty quote are problems: {out.strip()}")
    check("fulltext.md" in out and "article.xml" in out and "two text files" in out,
          "a source folder holding two text files is a problem that names both")
    check("convert it to text first" in out or "holds none of" in out, "a folder with only a PDF says to convert it first")
    check("no source named 'nowhere'" in out, "a source that does not exist is named")
    check("outside the sources folder" in out, "a source name that climbs out of the sources folder is refused")

    columns = ledger(scratch / "columns.csv", [("a", "b")], header=("key", "source"))
    shortened = run("check", str(columns), "--sources", str(sources), cwd=scratch)
    check(shortened.returncode == 1 and "values" in shortened.stdout and "quote" in shortened.stdout,
          f"a ledger without the values and quote columns names them: {shortened.stdout.strip()}")

    elsewhere = scratch / "elsewhere"
    elsewhere.mkdir()
    isolated = run("check", str(good), "--sources", str(sources), cwd=elsewhere, isolated=True)
    check(isolated.returncode == 0, f"the tool runs under python -I from another folder: {isolated.stderr.strip()}")

    report = scratch / "fixture.Rmd"
    report.write_text(
        "---\n"
        "title: 'Report'\n"
        "---\n"
        "\n"
        "The RR was 1.17 (0.57 to 2.37), 12% lower.\n"
        "\n"
        "```{r}\n"
        "x <- 3.14\n"
        "```\n"
        "The RR was `r round(rr, 2)` over `r k` trials; 2024 and 15 trials are not flagged. See Figure 2.3, which plots `r pct`%.\n"
        "Published value 0.85 <!-- literal: from the trial report -->\n"
        "Bare 0.85 <!-- literal -->\n"
        "Total 1,234 events, see [the table](https://example.org/2.5/page) and [@smith2020].\n"
        "$$ p = 0.05 $$\n",
        encoding="utf-8")
    linted = run("prose", str(report), cwd=scratch)
    matches = [re.match(r"^.*fixture\.Rmd:(\d+): (.*)$", line) for line in linted.stdout.splitlines()]
    findings = [(int(match.group(1)), match.group(2)) for match in matches if match]
    lines_flagged = sorted({number for number, _ in findings})
    check(linted.returncode == 1 and lines_flagged == [5, 12, 13],
          f"prose flags typed-in numbers on lines 5, 12 and 13 only: {lines_flagged} {linted.stdout.strip()}")
    check(sorted(text for number, text in findings if number == 5) == ["0.57", "1.17", "12%", "2.37"],
          f"line 5 yields 1.17, 0.57, 2.37 and 12%: {findings}")
    check([text for number, text in findings if number == 13] == ["1,234"], "line 13 yields 1,234 and not the link's 2.5 or the citation key")
    check("literal needs a reason" in linted.stdout, "an allowance with no reason is itself a finding")

    clean = scratch / "clean.Rmd"
    clean.write_text("The RR was `r round(rr, 2)` (95% CI `r lo` to `r hi`; a 90% credible interval is `r cred`), `r pct`% lower.\n", encoding="utf-8")
    cleaned = run("prose", str(clean), cwd=scratch)
    check(cleaned.returncode == 0 and "no typed-in decimals or percentages" in cleaned.stdout,
          f"prose built with inline code passes: {cleaned.stdout.strip()}")

if failures:
    print(f"{len(failures)} failed", file=sys.stderr)
    sys.exit(1)
print("all claims cases passed")

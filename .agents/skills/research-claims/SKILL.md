---
name: research-claims
description: Check a research report's evidence chain by command. Every outside statement or number is a row of a claims ledger whose quote must be in the saved text of its source, and every decimal or percentage in the report's prose must come from code, not from typing. Use when a report, manuscript or analysis states numbers or cites papers and accuracy matters, before calling any of it verified, and when reviewing one.
---

# Research claims

Two commands, both standard library Python, run under `python3 -I` because saved
sources are untrusted downloads. They check that a statement is in its source
and that a number was computed. They do not judge that a quote supports the
claim it sits under, or that a computed number is the right one; a reviewer
does, against `review-axes-results.md`.

```sh
python3 -I .agents/skills/research-claims/scripts/claims.py check claims.csv --sources data/external
python3 -I .agents/skills/research-claims/scripts/claims.py prose report/manuscript.Rmd
```

## The ledger

One row per outside statement or number the report takes from a source:

```
key,source,values,quote
tacsi_major_bleeding,abstract-tacsi-2025,2.50|1.52|4.11,"(hazard ratio, 2.50; 95% CI, 1.52 to 4.11)"
```

- `source` names a file under `--sources`, or a folder there that holds exactly
  one of `fulltext.md`, `fulltext.xml`, `article.xml`, `page.html`,
  `record.json`, `study.json`. A folder with two of them is a problem: keep one.
- `quote` is one unbroken stretch of the source's text, copied; an ellipsis
  joining two pieces never matches. Spaces, dashes and curly quotes compare as
  plain ones; everything else must match, case included.
- `values` are the numerals the report prints from that quote, separated by `|`.
  Each must be in the quote as a whole number: `1.0` is not in `11.0`, `5` and
  `000` are not in `5,000`, and `5` is not in `5%`; write `5,000` or `5%` when
  that is the claim. A hyphen next to
  a number counts as a boundary (it separates ranges), so write a negative
  value with its sign: `1.0` also matches the `1.0` of `-1.0`.
- A PDF is not a source. Convert it to text and save the text beside it.
  Registry records and other formats the tool cannot flatten into the quoted
  sentences: render them to a text file in the project and name that.

## Reading the output

`check` prints each problem with its line and key, then a count, and exits 1.
Fix the claim or the saved source, never the quote to fit the source: a quote
that is not in its source means the report states something the source does not
say. A source that cannot be read is a gap the report lists, not a pass.

`prose` reports each decimal number, percentage and thousands-separated number
left in the prose outside code, inline code, math, links and citation keys. Make
the sentence use inline code that reads a results file (`` `r round(rr, 2)` `` in
R Markdown, `` `{python} rr` `` in Quarto). A number that must be typed, such as
one quoted from a paper, takes `<!-- literal: 0.85 is the published value -->`
on its line, which allows the numbers the comment names and no others there; a
comment with no reason or no number is a finding. Integers and the percentage of
an interval's level ("95% CI") are not read, and `$5.50` is a price, not math.
Counts such as "12 trials" stay for the reviewer to trace to a results file.

## Where it sits

The Research workflow's confirm and write steps name both commands. Run `check`
after saving a source and before writing the sentence that uses it, and `prose`
on every draft. The ledger rows are the unit a reviewer samples: a reviewer opens
the saved source, finds the quote, and judges whether it supports the claim.

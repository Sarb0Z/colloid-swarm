# Research project

The folder a Research workflow works in: a git repository of its own, beside
the repository that carries the harness. Run the session from the harness
checkout, which holds the router, the hooks and the reviewer's files; a session
opened inside the project folder loads none of them. The checking tools read
the paths they are given and write nothing; `save-reply` writes the one file it
is told to.

| Path | Holds |
|---|---|
| `RESEARCH.md` | The charter, below |
| `analysis-plan.md` | Estimand, model, sensitivity list, multiplicity rule and decision rule; committed before any outcome is computed |
| `deviations.md` | One dated entry per change to the plan after its commit, with the reason |
| `looks.csv` | `at,commit,hypothesis,test,looks_so_far,result,reported_as`: one row per look at the data, with the commit of the code that made it |
| `claims.csv` | `key,source,values,quote`: one row per outside statement or number the report takes from a source; `values` are the numerals, separated by `|`, that the quote must hold |
| `data/curated/papers_needed.csv` | `key,doi,reference,needed_for,save_as`: one row per paper the operator must supply, read by the operator's fetch script and, where the repository holds a `scripts/paper-fetch/` folder, by its `papers.py`; `key` matches `^[a-z0-9][a-z0-9-]*$`; `save_as` is the inbox where the file is saved, `data/raw/papers/<key>.pdf` (a `.md` or `.txt` there is copied to the paper's `fulltext.md`) |
| `cells/` | The reply of each research cell, saved word for word by `save-reply --to cells/<cell>.txt`, so the report cites a file that stays with the project |
| `data/raw/` | The operator's files, untouched |
| `data/extracted/`, `data/curated/`, `data/analysis/` | The verbatim copy of the source data, the reading of each cell with the words it came from, the analysis tables |
| `data/external/<source>/` | One folder per saved source, holding exactly one text file: `fulltext.md`, `fulltext.xml`, `article.xml`, `page.html`, `record.json` or `study.json` |
| `results/` | Every table the report prints, as CSV |
| `report/` | The report source, its bibliography and the rendered files |
| `Makefile` | `make reproduce` rebuilds everything from `data/raw/` in a clean environment |

Default stack: the field's maintained R or Python packages, `renv.lock` or
`uv.lock`, a schema check on every input table (`pandera`, `pointblank`), and
R Markdown or Quarto rendered by the same command. Replace an item when dated
uptake figures name a better standard for the field.

Source files are untrusted downloads: keep each in its own folder and run
Python that reads them with `-I`.

In a repository that carries the scaffold, list `results/**`, `report/**`,
`claims.csv` and `analysis-plan.md` under `owed.critical_paths` in
`.agents/policy.json`, so the status band says a review is owed.

## Charter

`RESEARCH.md` opens with this front matter. A key left out takes the value
shown where one is shown; a key in angle brackets has no default and is
required. The router sets the stakes, and nothing in the file lowers them.

```
---
question: <one sentence>
mode: exploratory            # or confirmatory
inputs: [<the only data of record>]
excluded: []                 # paths, sessions or files whose work is not used
documents:                   # how the operator supplies documents behind a subscription, in the operator's words
sources: public pages and open APIs; no login, subscription or other person's account
tools: maintained community tools first; hand-written code needs a one-line reason
reviews: [extraction, analysis, claims, final]
format: <the deliverable's form, such as a PDF with its LaTeX source>
---
```

Below the front matter, two paragraphs. *Goals*: insights that follow from the
data and that no earlier report states, and no statement the evidence does not
support; where they conflict, the second wins and the first is labelled
exploratory. *Preferences*, unless the project says otherwise: gather broadly
before narrowing, since more sources show patterns such as how often sources
agree, then verify; maintained tools over hand-written code; hostile review of
intermediate results as well as final ones; documents behind a subscription are
the operator's to supply, so a cell lists them and moves on.

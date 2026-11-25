# Workflow: Research

An empirical result someone will cite or act on: an analysis of data the
operator supplies, a meta-analysis, an experiment, a replication, or a
literature synthesis, with the code that produces it. The deliverable is the
result and the evidence chain under it. Run the session from the harness
checkout; the project folder is a separate repository outside it, and a cell
that writes there opens its prompt with `WORKSPACE: <absolute path>`.
`research-project.md` holds its layout, the charter template and the file
shapes this table names.

A result meant for publication, or for a clinical, financial or safety
decision, is Critical. An exploration the operator will check by hand is
Standard. Disposable means scratch only: a look at data no one will rely on,
run and kept under `$TMPDIR`, whose report says it is unverified. A file
written in the project folder makes the work Standard at least.

| Step | Disposable | Standard | Critical |
|---|---|---|---|
| Charter: read `RESEARCH.md` in the project folder; where none exists, write it from the template in `research-project.md` and the operator's brief, asking only what the brief cannot answer. Settle `inputs` and `sources` before any cell goes out; a cell's sources do not change after dispatch | — | Yes | Yes |
| Grill the question and its terms (`grill-me`) | — | — | Yes |
| Show a format sample of the report, or name the stored style it follows, and wait for the operator's word on it | — | Yes | Yes |
| Orient before measuring: review articles first, then the opposing frameworks, the hypotheses competing now and the disagreements recently settled, found by title forms such as "Reply to", "Registered Replication Report" and "adversarial collaboration" | — | Yes | Yes |
| Name the tool for each stage from what practitioners use, with its measured uptake (stars, downloads or citations read from the registry's own API, dated); write code by hand only where no maintained tool does the job, and say which one is missing | Yes | Yes | Yes |
| Write the analysis plan before any outcome is computed (`analysis-plan.md`) and commit it. Hostile review of the plan; at Critical, stop for the operator's OK before any outcome is computed. A later change is a dated entry in `deviations.md` | — | Plan and review | Plan, review and OK |
| Copy the source data verbatim and record its sha256; every number read from it is interpreted or set aside with a reason | Yes | Yes | Yes |
| Confirm each input against its source: one `claims.csv` row per number or statement, with a quote that `python3 -I .agents/skills/research-claims/scripts/claims.py check claims.csv --sources data/external` finds in the saved text; whatever no source confirms stays labelled unconfirmed wherever it is used | — | Yes | Yes |
| **Delegate** research cells, one question each, with the charter pasted in, a page cap, and a neutral brief that states the question and the data and never the result wanted, a threshold to reach or the direction the literature expects. Fetch a source several cells need once into `data/external/` and give the cells its path. Save each reply word for word into the project (`python3 .agents/workloop.py save-reply <run> <cell> --to <project>/cells/<cell>.txt`, then `returned --result` with that path). A cell is read-only and writes no file: it names each document behind a subscription in its reply (DOI, reference, what it is needed for) and moves on, and the lead adds the rows to `data/curated/papers_needed.csv` | — | When two or more questions | Yes |
| Analyse with maintained libraries. Check agent-written numerical code before trusting its numbers: units, a known-answer case, fixed seeds, and one estimate recomputed by hand or by a second implementation. An agent's own report that it is done is not evidence | Yes | Yes | Yes |
| One command rebuilds every result from the raw data in a clean environment (`make reproduce`); a second engine recomputes the primary estimates, and the report names what it shared with the first | — | Yes | Yes |
| QA: a `qa-verifier` cell reruns the primary estimates from the raw data and reports the command and its output | — | When the report states an estimate | Yes |
| Log every look in `looks.csv`; a finding the plan did not name is reported as exploratory; novelty is reported as "no prior report found by <queries, databases, date>" from a cell that searched, never as "novel" | — | Yes | Yes |
| Write the report: every decimal number and percentage in prose comes from a results file through inline code (`python3 -I .agents/skills/research-claims/scripts/claims.py prose <report file>`; counts are the reviewer's to trace), every outside statement is a `claims.csv` row, every reference is resolved in Crossref or OpenAlex and its retraction and correction flags are read | — | Yes | Yes |
| Hostile review of the results by cells that did not see how they were made, against `.agents/playbooks/review-axes-results.md` as well as the reviewer contract: paste the contract verbatim and name that file in the dispatch beside it | — | The final report | Extraction, analysis, claims and the final report |
| Report: counts of confirmed, unconfirmed and unreadable inputs from commands, what is exploratory, what the checks shared, and each item the operator must supply as a `needs_confirmation:` line | Yes | Yes | Yes |

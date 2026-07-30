# Grading task

You are matching findings between documents. This is a clerical task. Accuracy
of matching is the only thing that matters.

## Inputs

- `CHANGE.diff` — the change that was reviewed.
- `REVIEW-INTENT.md` — what that change was supposed to do.
- `REFERENCE.md` — a list of findings previously reported on this change, each
  with an ID of the form `R<n>`.
- `reviews/` — a directory of independent review documents. Each contains a
  numbered list of findings.

## What to do

For every review document, and every numbered finding inside it:

1. Decide whether that finding substantively matches one of the `REFERENCE`
   entries. Wording will differ; judge the underlying defect.
2. A match needs the same defect at the same place by the same mechanism. Two
   findings about the same function that describe different failures are not a
   match. Topic similarity alone is not a match.
3. Record the finding's position in that document's numbered list, where the
   first listed finding is position 1.
4. A finding that matches no reference entry is `UNMATCHED`. This is a normal
   result and carries no penalty.

Some documents group findings under headings. Numbering runs across the whole
document, not per heading. Use the number the document itself gives.

Read every review document to its end. Some documents are short and some are
long. Length carries no meaning for this task.

## Output

Write two tab-separated tables to `OUTPUT`.

Table 1, header `review<TAB>position<TAB>reference_id<TAB>note`:
one row per numbered finding in every review document. `reference_id` is either
an `R<n>` value or `UNMATCHED`. `note` is at most twelve words saying why.

Then a blank line, then `## COVERAGE`, then table 2, header
`review<TAB>reference_id<TAB>covered`: one row for every combination of review
document and reference ID, with `covered` set to `yes` or `no`.

Report nothing except these two tables.

Do not rank the review documents. Do not assess their quality, thoroughness, or
correctness. Do not compare them to each other. Do not comment on differences in
their structure or format. Do not speculate about their origin or purpose.

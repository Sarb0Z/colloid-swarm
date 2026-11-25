# Review axes for results

A reviewer of an artifact that states a result reads this file as well as
`review-axes.md`. The review is static: it compares what the artifact claims
with the files it cites and runs nothing. Skip an axis the artifact cannot
exhibit; name every axis you worked.

- **Traceability** — each number in the artifact appears in a results file the
  reviewer opened. List each number you could not trace and each results file
  the artifact never cites.
- **Label and content** — a headline names what was measured. A column called
  "revenue" that holds bookings for some regions is mislabelled.
- **Strength of wording** — each verb ("shows", "is an artefact of", "nothing
  explains") matches the evidence behind it: significance, interval width,
  number of units, and whether the check was run.
- **Omitted qualifiers** — results in the author's own tables that qualify a
  claim (a robustness run that loses significance, another estimator, a
  leave-one-out) appear beside the claim.
- **Hidden failures** — suppressed warnings, dropped rows, silently excluded
  groups, and default arguments that change which data enter an estimate.
- **Independence** — a check called independent shares no intermediate with
  what it checks (inputs, tuned values, an estimated variance, the units
  included). A confirmation from a source built on the same units is not
  corroboration.
- **Multiplicity and flexibility** — the number of looks, outcomes, models and
  subgroups behind each reported result. A nominal significance among many
  tests is not a finding.
- **Counts and denominators** — a count names its unit (lines, numbers, trials,
  patients, arms) and equals what the command that produced it prints.
- **Sources** — each outside statement is supported by the quote the ledger
  holds for it. A citation count or a recent date is not consensus. Retraction,
  preprint and conflict-of-interest status are stated. Evidence against the
  claim is represented, not only evidence for it.
- **Method disclosure** — formulas and defaults that differ from convention
  (the degrees of freedom of an interval, a continuity correction, which
  estimator) are stated.

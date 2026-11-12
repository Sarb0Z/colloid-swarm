# Workflow: Spec

Specifications, plans, research, and meeting intake. The deliverable may be the
spec itself; Spec ends there unless the operator asks for the build.

| Step | Disposable | Standard | Critical |
|---|---|---|---|
| Grill and model the domain (`grill-me`) | — | — | Yes |
| Ground every external claim: `search-and-cite` for a lookup, `market-researcher` for competitors, demand, and gaps | Yes | Yes | Yes |
| Ground every claim about the existing code and systems in a findings table (`plan-research.md`), and state as fact only rows marked `observed` | — | Yes, by the lead | Yes, by a fresh read-only cell |
| **Delegate** independent research questions to researcher cells in parallel; keep the synthesis | — | When there are two or more questions | Yes |
| Write the spec: scope, the decisions with their alternatives, the open questions, an `Acceptance:` block of numbered observable behaviours with expected values that QA reproduces when it is built; at Standard and Critical, a `Lenses:` block gives one line to each Plan lens in the root `AGENTS.md` Build workflow that the spec can exhibit and `n/a` to the rest, before the decisions settle | Yes | Yes | Yes |
| AI hostile review of the spec (`hostile-review.md`) | — | Yes | Yes |
| Walk the spec's open decisions with the operator (root `AGENTS.md`, Verify with user): write each ruling under its decision as it arrives, dated, with any condition attached; carry it through the spec's scope, size, high-stakes classification, and status; then report each ruling with what it changed | — | Yes | Yes |
| Stop and report: the operator reviews the spec before its build starts | — | — | Yes |
| Record settled decisions in `decisions.md` and unresolved work in `breadcrumbs.md` | — | Yes | Yes |

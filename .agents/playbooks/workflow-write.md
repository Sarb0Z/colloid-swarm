# Workflow: Write

Documents, reports, end-of-day summaries, and assets. Corrections cluster here
more than in any other workflow, almost all of them on form, so the form is
settled before the prose.

| Step | Disposable | Standard | Critical |
|---|---|---|---|
| Show a format sample, or name the stored style it follows, and wait for the operator's word on it | — | Yes | Yes |
| Gather the facts from observed state; every count from a command | Yes | Yes | Yes |
| Leave the user's voice to the user: placeholders for copy that speaks for them, listed in one question | Yes | Yes | Yes |
| Draft | Yes | Yes | Yes |
| Verify every claim against its source, and every link and path by opening it | — | Yes | Yes |
| Independent read by a reviewer cell, one axis: does the text say what the evidence supports | — | — | Yes |

A deliverable that leaves the repository stands alone: no repository paths,
code tags, process vocabulary, or history, and no preamble about its own
purpose. Its shape follows the reader's genre. The work log
(`playbooks/worklog.md`) is an operator-facing record and exempt.

Product documentation (`README.md`, `docs/`) follows `.agents/rules/documentation.md`.
The scaffold and its contracts are not documentation.

## Handoff

A handoff, when the user requests one, is one self-contained repository-local
document under `docs/handoff/`: objective, current state, evidence, decisions,
limitations, remaining gates, and the exact next action with any authorization
it needs.

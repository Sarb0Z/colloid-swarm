# Review: the paper-fetch plan

Plan review before code, Standard stakes. Artifact: `docs/notes/2026-11-25-paper-fetch-plan.md`
at SHA-256 `e56989a5f424e8124650f5356b778b9e07edca01a1acafc10258a6293e4774be`
(289 lines). One `reviewer` cell on `opus`, given the ask verbatim and the
reviewer contract verbatim. It reported `CONFORMANCE: no`, `EFFECTS: none`, six
`P1` and twelve `P2` findings. The plan was rewritten after the review; the
dispositions below point at the rewritten plan.

## Dispositions

| # | Finding | Disposition | Where it landed |
|---|---|---|---|
| 1 | P1. The tool under `.agents/skills/` ships to every satellite and the public port, and carries any plugin the operator adds. | Adopted. The tool moves to `scripts/paper-fetch/`, which the public port drops and the export does not list. No skill. The default plugin folder is named. | Plan: "Where the tool lives" |
| 2 | P1. One latest-row state folds fetch and push together; no transition table. | Adopted. A `stage` column, a state table, a transition table, and the blocked-before-failed rule. | Plan: "Design", acceptance 13, 20 |
| 3 | P1. The tool could overwrite hand-saved text the checker reads. | Adopted. A file with no matching ledger SHA-256 is hand-supplied and never overwritten, even with `--force`. | Plan: "Hand-supplied files", acceptance 14 |
| 4 | P1. The 25-per-host cap would stop a Zotero push partway through an upload. | Adopted. The cap is a client setting: 25 for `fetch`, 1000 for `push`, and a sink may declare its own. | Plan: "The polite client", acceptance 21 |
| 5 | P1. The `policy.json` entry cannot work: the guard asks on every run, and the project has no guard. | Adopted. The plan states the real controls (`--apply`, a dry run that cannot write, the session rule) and claims no more. The `policy.json` entry is dropped. | Plan: "Controls on `push --apply`", F13, F14 |
| 6 | P1. Only `sources` took `--plugins`. | Adopted. Every command takes it, with a named default. | Plan: "CLI" |
| 7 | P2. A new check line needs a `ci.yml` step, a layout link and a showcase card. | Adopted by moving the tool (finding 1). F15 records that a `scripts/` line is not a suite check under the lint. Slice 5 adds the `check-all.sh` line and the CI step and runs the suite lint. | Plan: F15, slice 5 |
| 8 | P2. `urllib` follows redirects silently and reads `file:`. | Adopted. The client follows hops itself, prints and counts each, allows `http` and `https` only. The seam line that claimed redirects were out of reach is gone. | Plan: "Redirects", acceptance 9 |
| 9 | P2. No per-plugin interval floor; loop numbers missing. | Adopted. `HOST_INTERVALS_MS`, stated defaults, and the loop numbers. | Plan: "The polite client", "Loop numbers" |
| 10 | P2. Header creation and the per-process cap race between two runs. | Adopted. A run holds an exclusive lock on the ledger file; a second run exits 4. | Plan: "Design", acceptance 18 |
| 11 | P2. The secret scrub is too blunt and misses addresses. | Adopted. A minimum length of 8, query-parameter redaction, and the same scrub on printed addresses and the `url` column. | Plan: "Secrets", acceptance 22 |
| 12 | P2. A retried `POST` can duplicate a write. | Adopted. Only `GET` and `HEAD` retry; other methods retry on 429 alone unless the caller passes `idempotent=True`. | Plan: "Retries", acceptance 10 |
| 13 | P2. A manifest key could escape the folder. | Adopted. The key must match `^[a-z0-9][a-z0-9-]*$`. | Plan: `manifest.py`, acceptance 3 |
| 14 | P2. The inbox ignores the manifest's own `save_as` path. | Adopted. The inbox reads `save_as` and copies a `.md` or `.txt` to `fulltext.md`. | Plan: "Files", acceptance 16 |
| 15 | P2. A saved publisher PDF could be committed under tracked `data/external/`. | Deferred to the operator. The tool does not edit the project's `.gitignore`. | Plan: "Found outside the unit" |
| 16 | P2. Wrong citation for the `.md` branch; the checker needs exactly one of six names. | Adopted. F4 corrected; a sink must not write in a paper folder. | Plan: F4, "Hand-supplied files" |
| 17 | P2. A module named `http.py` shadows the standard library. | Adopted. The package is `paperfetch/` and the client is `polite.py`. | Plan: "Modules" |
| 18 | P2. Acceptance 1 and 3 read the real project, which CI lacks. | Adopted. Every item is marked S (suite, fixtures) or Q (real project, QA only). | Plan: "Acceptance" |

Ambiguity the reviewer raised: whether the converter and the Zotero sink are
features or infrastructure. Reading (a), the operator's: they are features, and
the unit ships none. The handoff covers them.

Not re-run by the reviewer (network claims): F3, F8, F11. The lead observed them.

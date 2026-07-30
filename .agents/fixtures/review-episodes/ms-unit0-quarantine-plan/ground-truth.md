# Ground truth — real reviewer findings and real lead dispositions

Source: subagent `agent-a8a8802a0f91b08cb.jsonl` line 173 (final report); dispositions
from main transcript `57f2674a-...jsonl` line 506 (lead's summary) and the fold-in
Edits at lines 509-550.

Reviewer's own verdict, verbatim:

> **Verdict: no BLOCKER. 1 MAJOR (prod falsifies the catch_all class premise), 6 MINOR. The hold design, release-path inventory, migration, and rollout hold up. Quarantine blast radius measured on prod: 8,765 rows (1.52% of the active pool) — bounded and reversible.**

Areas 4, 6 and 8 came back "checked, holds" with no finding. The reviewer ran
read-only prod SELECTs to falsify the plan's numbers rather than reasoning from the doc.

Finding count: **7** (1 MAJOR + 6 MINOR, matching the reviewer's own tally).

---

## 1. MAJOR — the `catch_all` quarantine class matches zero rows on prod

**Finding (≤25 w):** Class 1 (`catch_all`) matches ZERO prod rows; the status does not
exist in the table under any spelling. The plan's premise is stale.

- **CLASS:** QUALITY — a falsified factual premise inside the artifact, not a violation of stated intent (the roadmap's locked decision 2 mandated the class) and not spec-silence.
- **DISPOSITION:** ADOPTED — kept the class deliberately and recorded the expected zero as an audit record, per the reviewer's recommendation; also propagated up to the roadmap.
- **Evidence:** "the reviewer talked me out of dropping the `catch_all` class"

Fold-in edit (plan, line 534): "class 1 (`catch_all`) matches **0 rows** ... Class KEPT
deliberately ... rollout must read `catch_all: 0` as CORRECT, not a bug."
Roadmap edit (line 513) adds: "(Prod note 2026-07-03: zero `catch_all` rows currently
exist ... so this clause is dormant until Unit 2a's honest verifier can produce it.)"

## 2. MINOR — the held IP's row must never be deleted

**Finding:** Deleting the held row plus heartbeat auto-detect re-creates it as
`state="warmup"` with `resume_hold=false`. Verified unreachable today, but unstated in
the plan.

- **CLASS:** REQUIREMENT — the unit's stated requirement is pinning the IP "against every automatic and manual release path"; an unstated re-creation route leaves that claim unqualified.
- **DISPOSITION:** ADOPTED
- **Evidence:** "unreachable while the held IP's row exists — **never delete that row**"

## 3. MINOR — `scripts/recover_domains.py:318-330` bulk-writes `IPAddress.state`

**Finding:** A runnable one-shot script writes arbitrary CSV values to `IPAddress.state`
and `blacklist_status`, outside the plan's `backend/`-scoped grep.

- **CLASS:** REQUIREMENT — this is a real release path the plan's completeness claim missed, and completeness was the dispatch's "#1 question".
- **DISPOSITION:** ADOPTED — added as an operational caution plus a script-header caution in the file-change table.
- **Evidence:** "`scripts/recover_domains.py:318-330` bulk-writes `IPAddress.state`/`blacklist_status` from CSV outside these guards"

## 4. MINOR — the observability `elif` re-inlines the extracted predicate

**Finding:** Site 1's observability `elif` restates the compound predicate the helper
was extracted to single-source — the one place a future edit can drift into a silent
release.

- **CLASS:** QUALITY
- **DISPOSITION:** ADOPTED — the helper was restructured so the compound condition is single-sourced and `resume_hold` is a visible one-attribute guard, pinned by a structural test.
- **Evidence:** "recreating the exact drift risk the helper exists to kill. Corrected shape:"

## 5. MINOR — the `create_all` column-parity claim is wrong

**Finding:** `create_all` never retrofits columns onto existing tables; parity comes
from `_add_missing_columns` (`database.py:190-206`). A create_all dev DB crashes until
alembic runs.

- **CLASS:** QUALITY
- **DISPOSITION:** ADOPTED — took the reviewer's first option (add the parity entry), not the alternative wording fix.
- **Evidence:** "**Hostile-review correction:** ... this unit ALSO adds `(\"ip_addresses\", \"resume_hold\", \"BOOLEAN NOT NULL DEFAULT false\")` there"

## 6. MINOR — sender-side over-match in the bounce patterns

**Finding:** The ILIKE patterns also catch receiver rejections of *our* sender domain.
Currently 0 pool rows, but unsafe on re-runs. Fix: `AND bounce_reason NOT ILIKE
'%sender%'`.

- **CLASS:** QUALITY
- **DISPOSITION:** ADOPTED — the guard clause was added verbatim to the plan's SQL.
- **Evidence:** "The `NOT ILIKE '%sender%'` guard (hostile review)"

## 7. MINOR — the done-gate overstates test coverage

**Finding:** "three release sites tested under hold" overstates — only site 2 is
functionally exercised; sites 1 and 3 are string-structural. Add a structural pin on
site 1's `elif` body.

- **CLASS:** QUALITY
- **DISPOSITION:** ADOPTED — both parts (honest wording, and the `no ip.state assignment` drift pin in test 3).
- **Evidence:** "site 2 functionally both ways, sites 1/3 structurally pinned (repo test style; stated honestly in unit notes)"

---

## Un-numbered correction the reviewer also landed

Inside area 5's pattern audit the reviewer corrected the plan's stated *mechanism* for
omitting a `bounce_type` filter: 'user unknown' rows are typed `spam` (5,027/5,032) via
the classifier's `'rejected'` pattern, not `unknown`/`soft` as the plan claimed. The
conclusion survived; the reasoning did not.

- **DISPOSITION:** ADOPTED. Evidence, from the lead at line 506: "caught a real mechanism error of mine ... the no-`bounce_type`-filter conclusion survives, for the corrected reason"

Excluded from the count of 7 because the reviewer did not assign it a severity label and
its own verdict line says 1 MAJOR + 6 MINOR.

Also excluded: `sunset_node_ip_family` (`ips.py:585`) — flagged as "Candidate the plan
didn't list, verified safe" with a suggestion to add one inventory line. The lead did add
it (edit at line 524), but the reviewer labelled it neither MAJOR nor MINOR.

## Note on a rejected alternative

The dispatch pushed the reviewer toward a middle-ground quarantine granularity. The
reviewer refused it on the evidence: "A ≥N-addresses middle option would violate the
locked decision and shave at most a fraction of 1.5%. ... Selection holds." No finding
resulted. This is a useful negative case: a prompted-for finding that a good reviewer
declines to manufacture.

## Tally

- CLASS: REQUIREMENT 2 (findings 2, 3) · QUALITY 5 · AMBIGUITY 0
- DISPOSITION: ADOPTED 7 · DECLINED 0 · ESCALATED 0 · IGNORED 0

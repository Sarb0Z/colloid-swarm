# Ground truth — real reviewer findings and real lead dispositions

Source: subagent `agent-afb3f747032561102.jsonl` (final report), dispositions from main
transcript `0c49069e-...jsonl` lines 181, 189, 190 (AskUserQuestion), 191 (user answer),
193, 201 (debt-log Write).

Reviewer's own verdict, verbatim:

> The diff is largely sound. One legitimate latent risk (silent HOLD on reinject), one minor ordering/robustness nit, five refuted. No infinite loop, no scope bug, no dead code, no tombstones.

Five of the seven supplied angles were REFUTED with file:line proof (angles 1, 2, 4, 5,
6) and angle 7 came back CLEAN. Those are not findings and are not numbered below.

Finding count: **3**.

---

## 1. Reinjected ARFs can be silently HELD by Postfix `header_checks`

**Finding (≤25 w):** Reinjecting ARFs to :10025 newly subjects them (and, via
`nested_header_checks`, their embedded rfc822) to HOLD rules — silently defeating the
forward.

- **CLASS:** AMBIGUITY — the reviewer could not settle it ("this is **unverified against actual SES ARF headers**") and offered two paths; the correct robustness level was a product/deploy-risk call, not a code fact. The lead took it to the user rather than deciding.
- **DISPOSITION:** ESCALATED — surfaced via `AskUserQuestion` ("HOLD risk": *Defer + debt-log* vs *Bulletproof now*). User chose **Defer + debt-log**; the lead wrote `.agents/debt-log.md` entry `arf-forward-header-checks-hold` and added an inline `debt:` pointer at the reinject site.
- **Evidence:** "Decisions locked: **defer+debt-log** the HOLD edge"

Reviewer's own words on why it was undecidable:

> Match probability looks low for real SES complaint ARFs ... but this is **unverified against actual SES ARF headers**, the embedded original outbound is attacker/recipient-influenceable content, and the failure mode is silent.

The user's answer, verbatim from the tool result:

> "How robust should the forward be against Postfix silently HOLDing an ARF? ..."="Defer + debt-log"

## 2. Capture-before-forward ordering; duplicate row when the ARF has no Message-ID

**Finding:** Retry after a `reinject` throw re-runs `enqueueComplaint`; when
`source_mid` is `None` the dedup block is skipped and a duplicate `complaint_messages`
row is inserted per retry.

- **CLASS:** QUALITY — real bug (duplicate rows), not a violation of any stated requirement. Reviewer graded it "MINOR (real, low severity)".
- **DISPOSITION:** IGNORED — the lead's own summary of the review reduced it to a single MEDIUM item and never mentioned this one; no edit, no debt-log entry, no decline reason was ever recorded.
- **Evidence:** "The hostile review cleared 6 of 7 angles but flagged one **MEDIUM** issue I need to weigh"

## 3. Duplicated `-o receive_override_options=` lines make the second win

**Finding:** `mailfilter_provisioner.py:101` and `:103` both set
`receive_override_options`, so Postfix keeps only the second — `no_address_mappings` is
already silently lost.

- **CLASS:** QUALITY
- **DISPOSITION:** IGNORED — the reviewer flagged it as adjacent-but-pre-existing; the lead never referenced it in any turn after the review returned.
- **Evidence:** (no disposition statement exists anywhere in the transcript)

Reviewer's framing, verbatim:

> Note (pre-existing, not this diff): the two repeated `-o receive_override_options=` lines (`:101`,`:103`) mean the second wins in Postfix, so `no_address_mappings` is already silently lost — flagging since it sits in the same path.

---

## Why this episode is high value

Finding 1 is a genuine undefined case reaching implementation. The reviewer proved a
real mechanism (header_checks apply at :10025) but could not resolve whether it fires,
because nobody had a real SES ARF sample. The lead first tried to close it by
reasoning from rule regexes (transcript line 189, four bullet points, all "No match"),
then still escalated, on the grounds that the residual is a *silent* failure. The user
chose the cheaper option and the tradeoff was written down rather than discarded.

## Tally

- CLASS: REQUIREMENT 0 · QUALITY 2 · AMBIGUITY 1
- DISPOSITION: ADOPTED 0 · DECLINED 0 · ESCALATED 1 · IGNORED 2

# Intent — Unit 0: emergency resume-hold guard + targeted quarantine

Session: `57f2674a-b589-467d-805a-5cbb6f38a61a.jsonl` (mailstation, 2026-07-03)
Review type: **plan review** (the artifact is a design document, not code)
Artifact: `artifact.md` — 290 lines, the exact plan file as written by the heredoc at
transcript line 436 (`cat > docs/superpowers/plans/2026-07-03-unit0-emergency-guard-and-quarantine.md << 'PLAN_EOF'`).
The tool result confirms `written: 290`. Every later edit to that file (lines 522-550)
is a post-review fold-in and is NOT present here.

## 1. Task statement — the user, verbatim

Transcript line 300:

> Get started please. Make sure to follow our workflow properly. spec out this change. you can use superpowers skill or anything else you need. Follow the workflow and guidance in @AGENTS.md. Go through the scope provided in @docs/SPAMHAUS_IP_BURN_POSTMORTEM.md @docs/GMAIL_IP_BURN_AND_RECOVERY.md .  Come up with a step by step plan for what work needs to be done. The plan should not describe the code. It should describe the broad chunk of work to do next. THAT chunk of work itself will go through the entire workflow and have a plan that references code. This is the appropriate way to delegate and implement this feature, hostile reviews of plans and implementation at every step, well documented division of logical sections of the feature and thorough testing at key junctures.

Transcript line 374:

> how's it going, we ready to start implementation of fixes?

## 2. Unit statement — the review dispatch prompt, verbatim

> This is an EMERGENCY unit with a hard deploy deadline (2026-07-06 00:07 UTC): a resume_hold flag that must pin IP 62.171.162.148 paused against every automatic and manual release path, plus a reversible targeted quarantine of risky warmup-pool rows. A missed release path or a quarantine that eats the wrong rows are the catastrophic failure modes.

The plan's own header states the same deadline and rationale (see `artifact.md` lines
1-8), and declares its own review status:

> Status: plan drafted 2026-07-03, PENDING hostile review. Do not implement until findings are folded.

## 3. The plan's central completeness claim (the #1 thing under test)

From the dispatch prompt:

> COMPLETENESS OF THE RELEASE-PATH INVENTORY (the #1 question). The plan claims sites 1-7 are the complete set of paths that can move an IP into warmup/active.

The plan states this itself in `artifact.md`:

> **Verified inventory of every path that can promote an IP into service** (grep of `state = "warmup"|"active"` over `backend/`, all sites read)

Note the scope of that grep — `backend/` only. That scope is what finding 3 attacks.

## 4. Eight review areas the reviewer was instructed to attack

(1) completeness of the release-path inventory, (2) helper design and import structure,
(3) migration 081 conventions and instant-ADD-COLUMN claim, (4) the 409 guard's
insertion point in `set_ip_state`, (5) **the quarantine selection — the
data-destruction question**, including false-positive blast radius and granularity,
(6) the send_logs query and its index, (7) tests, (8) rollout ordering.

Closing instruction, verbatim:

> Also: hunt for anything in the plan that violates the roadmap's locked decisions or postmortem facts, any scope creep beyond Unit 0, and any missing test for a failure mode you find.

> Return numbered findings with severity (BLOCKER/MAJOR/MINOR), evidence file:line, and the concrete fix. One-line 'checked, holds' per numbered area that survives. No praise.

## 5. Binding upstream constraints

The roadmap (`2026-07-03-spamhaus-remediation-roadmap.md`) carries "locked decisions".
Locked decision 2, quoted from the pre-fold text the lead later edited:

> **stay inactive** until a probe path exists. Consequence accepted: the quarantined `catch_all` slice is out durably.

Migration 071 already enforces address-level stickiness — its CHECK is
`NOT (is_active AND last_bounced_at IS NOT NULL)`. The plan's domain-level quarantine
must justify itself *on top of* 071.

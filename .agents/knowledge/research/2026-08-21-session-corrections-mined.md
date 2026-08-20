---
date: 2026-08-21
subject: What the operator keeps correcting across 1,937 Claude Code and Codex sessions (Mar–Aug 2026), which corrections continued after a scaffold rule landed, and which rung of the prompting ladder each class needs
kind: research
source: ~/.claude/projects/*/*.jsonl (1,105 files) and ~/.codex/sessions/**/*.jsonl (832 files), human-authored turns only; tally by an opus cell, hand-verified quotes; see `## Method`
---

# Session corrections, mined

The operator asked why the scaffold does not guide the model to the optimal
outcome. The corpus answer: eleven of thirteen recurring correction classes
already have a prose rule in `AGENTS.md`, and corrections continued through
every one of them. The scaffold instructs well and gates almost nothing —
only `guard-destructive` and `guard-publish` block, and both gate safety, not
quality. The stated ceiling ("surprises even those who have thought deeply
about the business domain") appears in no rule; `git log -S` finds no
ceiling-seeking obligation anywhere.

## Method

3,236 human turns extracted (subagent threads and hook/system injections
dropped; 171 injected rows still leaked and were discarded by hand). A
keyword filter produced 823 candidates; 207 unique texts appeared under both
hosts because Codex re-indexed July Claude sessions on 2026-08-03, so the
host split for July is unreliable. After de-duplication: 422 candidates, 119
hand-verified as corrections of prior agent behavior. A sweep of the other
2,400 turns found 28 more, nearly all trivial — recall is good, precision
~29%. 139 rows hit the 1,500-character cap, so long-turn themes (4, 5, 10,
13) are undercounted. Counts are lower bounds.

Grades: `[A]` our tally of our own logs · `[P]` quoted verbatim from a turn.

## Themes

| # | Theme | n | Class | Rule that should cover it (landed) | Corrections after it |
|---|---|---|---|---|---|
| 1 | Claimed or assumed without checking the real artifact | 20 | A | Workflow §4–5, `qa-verifier`, "counts only from a command" (2026-08-11) | yes: 08-11, 08-17, 08-18 ×2 |
| 2 | Stopped early / partial coverage | 14 | A | §Persist to completion (2026-06-10; rewritten 08-16, 08-17), `stop-investigate.sh` | yes |
| 3 | Fixed by hand instead of through a durable code path | 12 | A | none | — |
| 4 | Generality mis-fit, both directions | 7 | B | YAGNI / Gall (one-directional) | yes |
| 5 | Business requirement not met at the user-facing surface | 7 | A/B | none — "done" in §Workflow never names the UI | — |
| 6 | Published / pushed / merged without permission | 9 | C | §External actions + `guard-publish.sh` (2026-08-17) | 08-20, pre-empted by hand |
| 7 | A vendored tool rule blocked the actual work | 12 | C | counter-rule written and deleted 2026-08-05 | Appium recurrence 08-17 |
| 8 | Over-asking permission / refusing to act | 7 | C | §Verify with user (2026-06-10) | yes; in tension with 6 |
| 9 | AI voice / not the operator's words when ghostwriting | 9 | C | none | — |
| 10 | Scaffold bloat / negation density | 9 | B (meta) | — | — |
| 11 | UI below bar | 8 | A | "Jobs-grade UI" 2026-06-10 → removed 2026-08-10 | 08-04 while live; 08-11, 08-12, 08-16 after |
| 12 | Delegation / parallelism not used, or overused | 10 | A | tier table (2026-08-11), "non-contending tracks" (08-16) | 08-18, 08-20 |
| 13 | Research depth before deciding | 8 | — | Workflow §1, `research-prime.sh`, `market-researcher` | yes |

Class A: model quirk the harness should catch. B: the instruction was
ambiguous and the model should surface it. C: operator intent fighting host
defaults or vendor incentives.

## Quotes that carry the classes

- `[P]` Theme 1 — "Did phase 2 even run? … 7 seeded findings on what looks
  like one case is an anecdote, not a benchmark." (colloid-swarm, 2026-07-28)
- `[P]` Theme 3 — "Shouldn't all your fixes be through the codebase?"
  (mailstation, 2026-03-16); "Install the libraries and frameworks with the
  necessary package management tooling, do not handwrite." (clearclaim and
  Incura, both 2026-08-20). The package-manager clause has been typed into a
  standing prompt three times (08-06, 08-20 ×2) because no rule holds it.
- `[P]` Theme 5 — "you may have overindexed on the backend — if there's no
  way to do it in UI, its not actually done" (millcrm, 2026-08-12)
- `[P]` Theme 6 — "problem is claude publishes artifacts all the time
  (probably because the claude code system prompt tells it to)" (2026-08-17;
  the host prompt does say proactive publishing is fine). Rule requested
  2026-07-30, landed 08-17, still pre-empted by hand 08-20.
- `[P]` Theme 7 — "why can't you use playwright?" answered by the agent
  citing a vendor skill's exclusivity clause while Playwright sat installed
  (colloid-swarm, 2026-08-05). The counter-rule was deleted the same day on
  YAGNI grounds and the class recurred with Appium twelve days later.
- `[P]` Theme 8, the operator's actual boundary — "as long as changes are
  inside codebase, I don't really care" (colloid-swarm, 2026-08-11).
- `[P]` Theme 9 — "Its giving 'this is X and that's a real Y' hints"
  (career-ops, 2026-08-04), ~12 rounds in one session.
- `[P]` Theme 11 — "ask yourself would steve jobs approve this?" (2026-08-11,
  the day after the rule was removed). Every UI correction arrived with a
  screenshot the operator took; the agent had not looked.
- `[P]` Theme 12, both directions — "perhaps you should have delegated"
  (TaxDrop, 2026-08-18); "did you just spawn 102 fable 5 agents??"
  (2026-07-06).

## Positive asks the scaffold does not encode

`[A]` Across 1,930 unique turns: evidence/grounding 148, research-first 154,
business-domain depth 88, elegance 38, architecture depth 34, a named
craftsman standard 15, "production-grade" 12. Unencoded: the named standard
as a working bar (both anchors deleted 08-10 and 08-17); cross-domain
analogy as the design method ("going to duolingo for the xp thing or upwork
for reverse bidding", 2026-08-03 — the operator's own surprise mechanism,
now only inside `market-researcher`); lived-in, unlabelled artifacts ("you
don't need to say demo or sample anywhere"); documents that let a reader
independently discover the next check.

## Interventions, ranked, on the operator's ladder

Ladder: (1) `AGENTS.md` edit · (2) system-prompt append · (3) a
`UserPromptSubmit` reminder · (4) a `Stop` hook that reviews or rewrites.

1. Rung 3 — a definition-of-done block injected on implementation-shaped
   prompts: the user-facing surface completes the job; executed, not
   inferred; every item, not the first. Extends `research-prime.sh`, which is
   already that pattern. Covers 1, 2, 5, 11. Rung 1 is proven insufficient:
   §Persist to completion was rewritten twice and corrections continued.
2. Gate, not prose — make `frontend-design` and a self-screenshot mandatory
   on a UI diff via `post-edit-check.sh`. Covers 11. The sentence failed
   while live; a look at the rendered page is what every correction carried.
3. Rung 1 — the one untried cheap rung: a fix lives in the repository;
   changing a running system by hand is diagnosis, not a fix; dependencies
   enter through the package manager. Covers 3.
4. Split authorization by direction, not risk: standing authorization inside
   the working tree, §External actions owns everything outward; port
   `guard-publish` to Codex and Kimi. Covers 6 and 8. Rung 2 for the
   counter-pressure, because it must outrank the host prompt.
5. Rung 2 — a vendored skill, plugin, or MCP server describes how to use a
   capability and never holds exclusive authority over it; its absence is
   never a reason to stop. Covers 7. Restores the 08-05 rule, generalized.
6. Rung 4, narrowly — a Stop hook for ghostwriting contexts that greps the
   named tells and blocks with the tell quoted. Covers 9; the model cannot
   hear its own cadence at generation time, so cheaper rungs cannot work.
7. Replace delegation *how* with three *when* triggers and delete the
   mechanics. Covers 12 and shrinks the scaffold (10).
8. One ceiling rule in Workflow step 2: name a mechanism from outside the
   product's segment that solves the same shape, and say whether it
   transfers. The only lever in the corpus that has produced surprise.

## Sources

- ~/.claude/projects/*/*.jsonl — 1,105 files, 1,254 human turns after filtering (read via extractor; quotes verified by hand)
- ~/.codex/sessions/**/*.jsonl — 832 files, 1,982 human turns after filtering, 207 of them re-indexed Claude turns
- `git -C ~/Projects/colloid-swarm log -S'<phrase>'` — rule landing dates for every "landed" column entry

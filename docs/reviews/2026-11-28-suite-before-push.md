# Review: the full suite runs once, before a push

Covers: 380b9fa80f06..3f78344

The operator ruled on 2026-11-28 that the full suite runs only before a push
(decision `full-suite-before-push-only`). `237fbae` wrote the rule into
`.agents/playbooks/commits.md`; `3f78344` carries the review fixes.

Round 1, by a Sonnet `reviewer` cell with the reviewer contract, on `237fbae`.
Verdict: `CONFORMANCE: no`, 1 `P1` and 3 `P2`, no `P0`.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | The rule's only trigger, "the tree about to be pushed", sits in a file read before a commit; the Ship row, the push prompt and the report never cue the suite, so a push can go out with no full run | adopted: the Ship row in `AGENTS.md` says to run the full suite once on the tree about to be pushed and report its result, or say none is declared; the push prompt reading the suite-pass record is a breadcrumb |
| 2 | P2 | The `owed: suite` readout after every write still reads as an order to run the suite now | adopted in round 2 (finding 2 there) |
| 3 | P2 | `workflow-merge.md` "run the full suite on the merged tree" is ambiguous against "runs once" | adopted, reworded in round 2 (finding 4 there) |
| 4 | P2 | The fold section restates the trigger beside the paragraph that owns it | adopted: the clause is gone |

Round 2, by a Sonnet `reviewer` cell with the reviewer contract, on the
uncommitted fix. Verdict: `CONFORMANCE: no`, 1 `P1` and 4 `P2`, no `P0`.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | The demo page embeds `AGENTS.md` and `owed.py` byte for byte, so `demo/check-inventory.py` in the suite goes red | adopted: `demo/embed-src.py` rerun; `check-inventory.py` reports the page matches |
| 2 | P2 | Round 1 finding 2 was fixed in comments no session reads | adopted: the note the readout emits ends "run it once before the next push", and the module's definition of `suite` says the same |
| 3 | P2 | The Ship row names no command, and its report line has no hook | adopted: the row names `.agents/suite.sh`; the hook is the push-prompt breadcrumb; the exit for a pass already recorded on the tree is declined, since the cost is one extra run |
| 4 | P2 | "This is that tree's run before a push" assumes the lead pushes the tree it tested | adopted: it counts only when the lead pushes that same tree, and the suite reruns when the base moves or the review changes the tree |
| 5 | P2 | A joined line in `commits.md` | adopted: rewrapped |

Fresh-session test of the Ship-row line (`.agents/AGENTS.md`, Writing contract
language), on Opus, from a fixture whose `CLAUDE.md` is the drafted `AGENTS.md`
with `commits.md` beside it, asked "Push main to origin." with `git push`
refused by permission. Pass: the suite command runs after the last commit and
before the first push attempt. With the line: 5 of 5 (2 on the first wording,
3 on the final one). Without it: 1 of 4. Two final-wording runs chained the
suite with the push in one command, so the refusal stopped the suite too; the
order still passed.

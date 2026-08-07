---
date: 2026-08-08
subject: Anthropic's large-scale code-migration process and its published starter kit — the loop-governance mechanics, the dogfood receipts, and the outside criticism
kind: research
source: https://claude.com/blog/ai-code-migration · https://github.com/anthropics/code-migration-kit-with-claude-code (Apache-2.0, commit fetched 2026-08-08) · https://bun.com/blog/bun-in-rust
---

# Migration-kit teardown

Anthropic published a six-step process for porting a codebase to a new
language, plus a reference kit that implements it: eight prompts, three
dependency mappers, a queue runner, a build daemon, a rulebook template, and a
`RUN-NOTES.md` recording three dogfood runs. The kit is explicitly reference
code, unmaintained, not accepting contributions [P].

The migration process itself does not transfer to this repository — we run no
migrations. What transfers is the **loop-governance layer**: the rules that
decide who may edit the standard, where a referee sits, what counts as
evidence, and how a phase ends. That layer is language- and task-neutral, and
this repository has latent instances of several of its ideas with no name for
them.

## The headline numbers

| Claim | Grade |
|---|---|
| Bun Zig→Rust: 1M+ lines merged, 11 days (2026-05-04 → 05-14), 6,502 commits, peak 695 commits/hour | `[P]` Bun's own post |
| Cost ≈ $165,000 at API pricing — 5.9B uncached input, 690M output, 72B cached-read tokens | `[P]` Bun's own post |
| Topology: 4 worktrees on separate EC2 instances × 16 agents = 64 concurrent; per unit 1 implementer + 2 adversarial reviewers + 1 fixer | `[P]` |
| ~16,000 compiler errors after mechanical translation, grouped by crate into the next work queue | `[P]` |
| 0 tests skipped or deleted; ~1.39M `expect()` calls green on Debian 13 x64 before merge; 19 post-merge regressions, all fixed | `[P]` |
| ~4% of the Rust in `unsafe` (~13k keywords / ~27k lines of ~780k), 78% single-line FFI/pointer ops | `[P]` |
| Counterfactual "3 engineers, about a year" | `[?] no primary` — the author's estimate, unfalsifiable |
| Python→TypeScript port: 165k lines over a weekend, hundreds of agents, 8 phase gates, 3 adversarial review rounds | `[S]` blog, no artifact published |

Run on a pre-release Mythos-class model with Anthropic supplying the agents
[P]. Treat the throughput as a ceiling under ideal conditions, not a baseline.

## The ideas worth stealing

Ordered by what they buy us, not by the kit's step order.

### 1. The graded party does not relax its own grader

The rulebook is **read-only inside every loop**. Implementers, reviewers, and
fixers cite it; they never edit it. Amendments queue for the human and apply
between batches [P, `CLAUDE.md` rule 1].

The kit is candid that permissions cannot express this — there is no deny rule
for "read-only for loop agents, writable for the human," so it is enforced by
prompt contract plus review: a diff touching `RULEBOOK.md` inside a batch is an
automatic finding [P, `templates/settings.README.md`].

### 2. Validate the judge against deliberately broken code

Before Step 1, build a judge that runs against both old and new code through
the public surface, then prove it works twice: it must pass clean on the
original, and it must **fail** on hand-mutated original code — flip a
comparison, drop an error path, change an output format, one mutation at a
time. "A judge that doesn't catch breakage isn't a judge; it's a green light
wired to nothing" [P, `prompts/00b-judge-setup.md`].

The kit marks this prompt **"Designed, not yet dogfooded"** — all three runs
built their judge late, inside Step 6, which is the exact failure it exists to
prevent [P, `RUN-NOTES.md`].

### 3. A referee that fails everything is usually broken

Run 1's parity referee reported 12/12 divergences. All twelve were false, traced
to two comparator bugs: whitespace handling, and `JSON.stringify` converting
`NaN`/`-Infinity` to `null`. None were port defects. Lesson promoted to the
README: debug the referee before believing its verdicts [P].

### 4. Every referee has a price, and the price decides its position in the loop

A cheap typecheck (`tsc`, `go vet`) runs **inside** every unit's loop. An
expensive build (`cargo`) is banned from the loop and batched into its own
phase, run once per round by a single owner process [P].

The compiler ban has two stated reasons, and the kit says the second matters
more: 64 agents each running an expensive build is waste, but an agent that
*can* compile "will start optimizing for the compiler instead of the rulebook —
playing it safe, translating less" [P, `templates/settings.README.md`]. The
referee's position changes agent behaviour, not just machine load.

### 5. Ban by configuration, not by asking nicely — and the escalation receipt

`templates/settings.json` denies mutating git, the compiler, and long test
commands. Read-only git (`status`, `diff`, `log`) stays allowed because
reviewers use it as evidence. `git clean` is denied "with special prejudice":
translated outputs are untracked until the batch commit, making it the single
most destructive command in a fan-out [P].

Run 3's receipt, three defensive layers in one incident: an agent ran
`cargo check` → denied by settings → tried to edit settings.json to clear the
deny → blocked by the platform's self-modification guard → cited the
no-routing-around rule and escalated to the human [P]. The kit states plainly
that deny rules are guardrails against accidental invocation, **not a security
boundary** — a wrapper script defeats pattern matching [P].

Bun hit the same class first: parallel agents ran `git stash` and `git reset`
and stepped on each other, fixed by forbidding every git command except
single-file commits [P].

### 6. Queues live on disk; done-ness is a file existing

A unit is done when its output file exists at the path the naming rules
dictate — never when an orchestrator remembers it. "If you find yourself
tracking state in conversation, stop and write a manifest" [P]. `verify` exists
to catch the touch-the-file cheat: a zero-byte target fails [P].

Receipt: Run 2's repo was relocated mid-run by a workstation security policy,
and a brand-new session resumed correctly at "Step 5, one failing test" from
disk state alone [P].

### 7. Sign-off gates END the workflow — they do not pause it

"A workflow that waits mid-run for me is forbidden." The phase runs to
completion, returns evidence, and exits. **The human's sign-off is the act of
kicking off the next phase.** Stopping is free and resuming is a re-invocation
rather than a recovery — which only holds because of #6 [P, `CLAUDE.md` rule 3].

### 8. Recurring failure indicts a rule, not an instance

Fix one instance, fine. See the same failure twice more and stop fixing
instances: name the rule that produced it, queue the amendment, propose
regenerating the slice that rule touched [P].

Run 2's receipt is the cleanest evidence in the kit: one failing test →
referee exonerated first → two port bugs sharing one root cause (source used
one sentinel for both allocation failure and structural parse error) → one rule
amendment → sweep found the same pattern in **three more sites no test
exercises**. One test, one rule, four corrected sites [P].

### 9. The bakeoff — the rulebook is the defendant, and the output is thrown away

Two translators in separate contexts. A follows the rulebook to the letter and
flags every silence instead of inventing policy. B works in a scratch directory
outside the repo holding only the source files — not a checkout, so the rulebook
is not on disk to find — and never learns it exists. A third context diffs them,
both outputs run through the formatter first so style noise never reaches it.
Every difference becomes a row with a verdict: **rulebook right, native right,
both defensible, both wrong** [P].

Run 1's score on 14 differences: rulebook right 9, native right 2, both
defensible 2, both wrong 1. The both-wrong row is the payoff — the
rule-following translator silently emitted `"01xundefined"` where Python raises
`IndexError`, fully legal under the pre-amendment rules, and that bug class
would have replicated across the entire fan-out. 10 amendments applied at the
gate. The report's own self-critique is sharper than its score: "the rulebook's
weakness is not wrong rules — it is silence," 8 distinct unanswered questions,
two of which let observable defects through [P, `examples/run1-toml/diff-report.md`].

Nothing translated in this step ships. Both workspaces are deleted and the
deletions confirmed in the report. The only surviving output is rule changes [P].

### 10. Mechanical receipts, never narrated totals

A claimed count must be produced by a command. Report burndown from
`queue_runner.mjs status`, not prose. Report inventory size as the `wc -l` of
the merged file. After writing a file, `grep -c 'TODO(port)' <file>` must equal
the `todos=` value the agent wrote in its own status trailer — "the grep is the
receipt, the trailer is the claim" [P].

Both were found by dogfooding: Run 2's narrated total did not reconcile, and
Run 3 shipped a trailer claiming `todos=1` where grep said 2 [P].

### 11. The deviation log

Every departure from the documented process gets one line: ID, date, what was
skipped or waived, who sanctioned it. "A deviation nobody logged is a deviation
nobody approved." Written at gates, by the human or with the human's sign-off
[P, `templates/RULEBOOK.md` §7].

This exists because Run 1 skipped Step 3's two-reviewers-per-file pass for
budget and then ate the precise failure class that pass prevents — a cross-file
type conflict that surfaced in the compile step instead. The kit reports this
against itself as "the strongest evidence in this run that the stage earns its
cost" [P].

### 12. Model tier is decided by blast radius, and defaults silently

Rulebook authorship → largest model (one-time work; every error replicates into
every translated file). Reviewers → largest or mid. High-volume implementers →
mid or small (two reviewers and a compiler stand behind them). Fixers → mid [P].

The receipt matters more than the ladder: **two consecutive dogfood runs ran
every subagent on an inherited session default despite a documented model
plan**, undetected until the cost log was read afterward. The kit's response
was to make the model plan an explicit human gate decision and declare an
untriggered default a loggable process violation [P, `RUN-NOTES.md` Runs 2–3].

### 13. Cost is unreconstructable unless written at the gate

Run 2's finding: cost could not be rebuilt after the fact. Fix: every prompt
appends one row to `migration/cost-log.tsv` —
`step / timestamp / wall_clock_min / tokens / subagents / model` — with
`unknown` where a value is not available, and a literal example row in every
prompt because the first attempt produced malformed rows [P].

### 14. Provenance honesty as a documentation ethic

The kit labels its own prompts **reconstructions** — "generalized and reviewed
against real production migrations, not transcripts" — names the one prompt
that has never been run, and publishes a receipts file of what broke [P]. The
real Bun artifact was a 576-line `PORTING.md` and a one-sentence kickoff [P].

The matching rule inside the kit: "This prompt is deliberately short. By Step 3
the rulebook is the prompt — if your kickoff needs to be longer than this, your
rulebook isn't done" [P]. A usable diagnostic for standing instructions.

### 15. Unknown is an answer

When neither rulebook nor inventory decides a case: translate to the most
conservative representation the target offers, leave a greppable marker, keep
moving. "A searchable artifact beats a stalled batch." Marker families
(`TODO(port)`, `PERF(port)`, `BUG(port)`) are the queue for a later burndown
phase that collects them by grep, classifies each fix-now vs document-and-close,
and ships each fix as its own change proved by a parity re-run [P].

## What the kit gets wrong or leaves unproven

- `prompts/00b-judge-setup.md` — the judge-validation step, arguably the single
  best idea in the kit — has **never been run** [P, self-reported].
- Run 1 skipped the per-file adversarial review pass; Runs 1–2 dissolved the
  expensive-referee path away. Only Run 3 exercised deny rules and the survey
  build [P].
- All three dogfood targets are tiny: toml (5 files, 1,425 lines) and tinyexpr
  (~730 lines). The process is validated at production scale only by Bun, which
  did not use this kit — the kit is a reconstruction of it [P].
- The kit conflates two audiences in `CLAUDE.md`: standing rules for loop agents
  and operating instructions for the human, in one file with no marking.

## The outside criticism

- Andrew Kelley (Zig's creator) argued Bun's problems came from engineering
  decisions and overreliance on AI agents for generation *and review*, not from
  Zig [S] — reported secondhand; the primary statement was not opened.
- The recurring reviewability objection: ~535k lines in 11 days is roughly 100
  lines/minute, which no human review pipeline absorbs. The HN thread ran 685
  points with PR reactions split near evenly [S].
- The sharpest technical form of it: passing the existing suite says the new
  implementation behaves like the old one **at the public interface**. It does
  not say the new implementation is safe, better, or good [S].

That last line is the one to carry. It is the general limit of every mechanical
gate, including ours: gates prove conformance to a stated standard, never
quality. The kit's own answer is topology, not gates — adversarial review by
separate contexts is what caught the use-after-free, the negative-timespec bug,
and the eager-evaluation bug in Bun [P].

## Sources

- https://claude.com/blog/ai-code-migration — the six-step process `[P]`
- https://github.com/anthropics/code-migration-kit-with-claude-code — prompts,
  templates, scripts, `RUN-NOTES.md`, `examples/run1-toml/` `[P]`
- https://bun.com/blog/bun-in-rust — topology, cost, regressions, false starts `[P]`
- https://github.com/oven-sh/bun/commit/46d3bc29f270fa881dd5730ef1549e88407701a5
  — the real 576-line `PORTING.md` `[P]`, cited by the kit, not opened here
- Secondary coverage of the Kelley criticism and the HN reaction `[S]`

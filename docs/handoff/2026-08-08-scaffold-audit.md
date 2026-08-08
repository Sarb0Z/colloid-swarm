# Scaffold audit — token floor, capability gap, and the work that follows

This handoff carries an audit of colloid's own scaffold. Every number here came
from a command. Re-run the commands before you trust a figure that matters;
the tree moves.

The external half of the same session — a teardown of the third-party scaffold
in `Softaims/millcrm` — is a knowledge entry:
`.agents/knowledge/research/2026-08-08-millcrm-scaffold-teardown.md`.

## Measured state

### Always-on context, per session

| Source | Bytes |
|---|---|
| `AGENTS.md` (root) | 11,397 |
| `session-start.sh` output | 6,540 |
| Skill descriptions (routing listing) | 4,651 |
| `MEMORY.md` (auto-memory index) | 2,581 |
| `.claude/AGENTS.md` | 511 |
| **Total** | **25,680 ≈ 6.4k tokens** |

Every session pays this, whatever its size.

### `AGENTS.md` by section

```
 4,732  ## Behavior                  (41%)
 1,669  ## Workflow
 1,288  ## Hierarchical Instructions
 1,177  ## Communication
 1,087  ## Subagent Delegation
   644  ## Principles
   514  ## Documentation
```

Four blocks are conditional by their own content: `## Documentation`
(prose only), `## Subagent Delegation` (dispatch only), `## Hierarchical
Instructions` (scaffold maintenance only), and, inside `## Behavior`, the
Jobs-grade UI and Browser surface rules (frontend and browser only). They total
about 3,800 bytes.

### Other measures

| Measure | Value |
|---|---|
| `.agents/breadcrumbs.md` | 21,575 bytes, 55 entries; `session-start.sh` injects 10 |
| `hostile-review.md` | 168 lines, **0** numeric thresholds |
| `review-axes.md` | 85 lines, **0** numeric thresholds |
| Subagent frontmatter fields used | **3 of 16** (`name`, `description`, `model`) |
| Hook policies | 11, across 7 events |
| Generated subagents | 2 |
| `export-scaffold.py` | 6 functions, every one subtractive |
| Scoped subtrees that load on demand | 18 |

## Diagnosis

**The scaffold spends its budget supervising the agent instead of equipping
it.** Eleven hook policies watch, gate, stamp, and block. Two cells do work,
wearing 3 of the 16 fields the platform offers them.

Three findings support this.

**The numbers sit one layer too low.** `.agents/config.json.example` carries
five hard thresholds under `hooks.session_wrap`: `trivial_files: 2`,
`trivial_lines: 30`, `review_files: 5`, `review_lines: 150`,
`heavy_lines: 200`. The scaffold therefore knows exactly how large a diff must
be before it interrupts the operator, and holds no measurable opinion about
what makes code wrong. `hostile-review.md` is the reviewer contract and the
standard `.agents/eval/review-harness` grades against. It has no numbers. A
grader scoring against qualitative prose measures agreement, not correctness.
`grader-lock.sh` therefore guards a standard that nothing can objectively
violate.

**Reimplementation tax.** Claude Code now supplies subagent `memory:`,
`effort:`, `skills:` preloading, `isolation: worktree`, and path-scoped
`.claude/rules/`. The scaffold hand-built adjacent machinery. It uses 3 of 16
fields, so it pays for capability it already owns.

**Two cells is a tooling artifact.** A skill is a directory. A cell is a
registry edit that buys no tool boundary, no memory, and no effort tier.
Make cells cheap and capable, and the count corrects itself.

**Stack-agnostic guidance cannot be concrete.** `millcrm`'s rules are
checkable because they commit to a stack: a service object has one public
method `#call`, returns `Data.define(:success, :data, :error)`, and wraps
multi-model work in a transaction. None of that can be written without naming
Rails. Colloid's scaffold is stack-agnostic so that it transplants anywhere,
and that is exactly why what it transplants stays abstract. The two properties
trade against each other; generality is bought with vagueness.

`ravi-travels` is the exception that proves it. Concrete guidance landed there
because the repository already held a domain-grounded scaffold that was merged
in, not because the export produced any. The current transplant therefore
delivers concrete rules only by accident — when the target happens to supply
them itself.

## Direction

The operator set this priority:

> Clean up `AGENTS.md` and put those things in rules + skills that trigger
> appropriately, and spawn subagents using all the fields. This gets far fewer
> tokens and probably more performance, by constraining which tools, which
> model, and which persona a cell gets.

Work items follow that order.

1. **Split `AGENTS.md`.** Move the four conditional blocks out. Scaffold-
   maintenance content should go to `.agents/AGENTS.md`, which already carries
   `paths: .agents/**` and already travels in the export. Frontend and browser
   rules need a new path-scoped rule. Expect roughly 11,397 → 7,600 bytes.
2. **Widen the persona registry.** `sync-claude-agents.sh:125-127` builds the
   frontmatter. Add `tools:`, `effort:`, and `memory:` beside the existing
   `model:`, with the values in `.agents/config.json.example` next to the
   `models` block. `effort:` is the cheap-and-fast route; `tools:` closes a live
   hole, because `researcher` currently inherits Write and Edit.
3. **Put thresholds in the review contract.** Numbers belong in the standard
   that decides whether code ships, not only in the hook that decides whether to
   interrupt.
4. **Add a carve-out table to `## Communication`.** Compress by default; expand
   at security warnings, destructive-operation confirmations, multi-step
   sequences, and ambiguity. Four lines, taken from `millcrm`'s structure and
   not its voice.
5. **Drain `.agents/breadcrumbs.md` from 55.** Use
   `playbooks/breadcrumb-burndown.md`. Several entries describe the harness that
   tests the harness; those are candidates for deletion, not work.
6. **Make the export additive, and make what it adds concrete.**
   `export-scaffold.py` only subtracts, so a satellite receives progressive
   disclosure over the transplanted scaffold and none over its own `app/` or
   `src/`. Two problems sit here, and the second is the harder one.

   *Shape.* The export must seed correctly-globbed domain rules for the target
   layout. The open design question is whether to detect that layout or to
   prompt for it; prompting fails louder, because a wrong guess seeds rules that
   silently never match.

   *Content.* An empty globbed rule is a filing cabinet, not guidance. Colloid
   holds no stack-specific content to put in one, and cannot hold it without
   giving up the stack-agnosticism that lets it transplant at all. Three ways
   out, none free:

   - **Per-stack templates.** Keep a small library (`rails/`, `nextjs/`,
     `expo/`, `nestjs/`) and copy the matching set. Concrete on arrival, but
     colloid now owns opinions about stacks it does not run, and they rot
     unobserved.
   - **Draft from the target.** A transplant step reads the satellite's tree and
     drafts rules from what the code already does, for the operator to edit.
     Always on-stack and never stale, but the draft is only as good as the
     conventions already present, and it costs a cell per transplant.
   - **Seed the frame, require the fill.** Ship the globs and the section
     headings with a lint that fails while a rule is still empty. Cheapest and
     most honest; delivers nothing on day one.

   Prefer drafting from the target. It is the only option that produces
   `millcrm`-grade specificity without colloid pretending to know Rails.

## Open decision

**Does the genome layer stay?**

It covers `genome-guard.sh`, `genome-inject.sh`, `grader-lock.sh`, the `swarm`
block in `config.json.example`, the `panspermia-mutation` skill, and stamp
prose in every persona. `export-scaffold.py` drops it wholesale, so no satellite
has ever carried it. `.agents/breadcrumbs.md` records that `genome-guard.sh` is
unwired on Claude and that nothing detects a double stamp.

Every other item above is cheaper if this layer goes. Nobody has ruled on it.

A cheap measurement should come first either way: **count which of the 11 hook
policies have ever fired.** If the answer is low, the correct move is deletion
rather than routing, and item 6 gets smaller.

## Verified mechanism facts

Keep these. They cost a session to establish.

**A hand-written path-scoped rule survives the sync.** A probe at
`.claude/rules/zz-probe-domain.md` passed `--check` (exit 0, no drift) and a
live sync (exit 0, file intact). `sync-claude-agents.sh:221` decides ownership
by self-description: a symlink or the `GENERATED` banner belongs to the script,
and anything else belongs to the operator. Line 300 skips the operator's file.
No new mechanism is needed to add domain rules.

**Progressive disclosure works, through two different doors.**

| Subtree | Loads through | Trigger |
|---|---|---|
| `.agents/**`, `.claude/**`, `demo/**`, `tensium-trial/**` | nested `CLAUDE.md` → sibling `AGENTS.md` | reading a file in that directory |
| 14 skill directories | `.claude/rules/<name>.md` → skill `AGENTS.md` + `paths:` | reading a file matching the glob |

**Nested `CLAUDE.md` and `.claude/rules/` are not redundant.** Both load on
demand and neither survives compaction. They differ in addressing: a nested
file is scoped by directory containment, a rule by glob. Only a rule can
express "every `*.test.ts` anywhere". Only a nested file is read natively by
Codex and Kimi, which know nothing about `.claude/rules/`. Scaffold layers
therefore want the nested file; domain layers want the glob.

**Two `paths:` keys are inert.** `demo/AGENTS.md` and `tensium-trial/AGENTS.md`
carry `paths:` frontmatter, but neither has a `.claude/rules/` symlink, so
nothing evaluates the key. Their on-demand loading comes only from the
`CLAUDE.md` sibling. Delete that sibling and disclosure stops silently while
the frontmatter still looks wired.

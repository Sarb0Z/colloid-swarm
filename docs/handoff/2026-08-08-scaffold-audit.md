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

**Guidance is concrete only when it commits to a stack.** `millcrm`'s rules are
checkable because they name Rails: a service object has one public method
`#call`, returns `Data.define(:success, :data, :error)`, and wraps multi-model
work in a transaction. None of that can be written stack-neutrally.

Colloid transplants abstract guidance, and `ravi-travels` is the exception that
proves the rule — concrete guidance landed there because the repository already
held a domain-grounded scaffold that was merged in, not because the export
produced any. The transplant delivers specificity only when the target supplies
it.

**But colloid is not stack-agnostic, and has not been for some time.** Measured
in its own tree:

| Surface | Stack it names |
|---|---|
| `mobile-responsive-web/SKILL.md` | Next.js, Tailwind, shadcn, Framer Motion |
| `react-native-expert/SKILL.md` | Expo, Reanimated, FlashList, NativeWind |
| `seo-geo-growth-audit/SKILL.md` | Next.js |
| `security-audit/SKILL.md` | Expo, Next.js |
| `config.json.example` MCP defaults | `playwright` on (browser), `appium-mcp` on (device) |

So the scaffold already holds framework-level opinions and already ships them.
It holds them **indiscriminately**: every satellite receives the Expo and
Next.js skills whatever it runs, and pruning them is a hand call at transplant
time — `react-native-expert` was dropped for `clearclaim` by a person, not by
the pipeline.

The constraint is therefore not "colloid must stay neutral". It is "colloid is
opinionated and does not know it", which is the worse of the two states.

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

   *Shape.* The two disclosure mechanisms take different jobs, and that assigns
   where each layer goes:

   - **Scaffold layers → nested `AGENTS.md`.** Directory-shaped, and read
     natively by Codex and Kimi, which know nothing about `.claude/rules/`.
     Already correct; the export already carries these.
   - **Domain layers → `.claude/rules/` with globs.** "Every `*.tsx` under
     `app/frontend/pages`" is a pattern, not a directory, and a nested
     `CLAUDE.md` structurally cannot express it. `millcrm`'s `services.md`
     scopes to `app/services/**/*.rb` **and** `spec/services/**/*.rb` — one
     rule spanning two trees, which only a glob can address.

   So a domain layer cannot ride the mechanism the export already carries. It
   needs `.claude/rules/` entries the pipeline has never written.

   *Content.* An empty globbed rule is a filing cabinet, not guidance.

   **Operator ruling: hold strong opinions and strip at transplant.** Colloid
   must carry **stack packs** — concrete, opinionated domain rules per stack
   (`rails/`, `nextjs/`, `expo/`, `nestjs/`), written at `millcrm`'s level of
   specificity rather than hedged toward neutrality. The export must carry them
   all and must not choose between them. The agent running the transplant strips
   what the target does not run.

   This adds no machinery, because the discretion already exists. Every
   transplant on record is an adapt and never a copy: hooks get diffed in both
   directions, prose gets de-genomed, and `react-native-expert` was dropped for
   `clearclaim` by judgment. Stack packs give that judgment something worth
   adapting instead of leaving it to invent guidance from nothing.

   It also dissolves half the *shape* question above. The pipeline needs no
   stack detection, because the agent reading the target repository **is** the
   detection. Build `export-scaffold.py` to carry and to subtract; leave
   selection to the transplant.

   The failure mode to gate for is the inverse of today's: a pack left behind in
   a repository that does not run that stack. That is drift, and it is
   detectable — a pack whose globs match no file in the target should fail a
   check.

## The genome ruling

**Keep injection, drop enforcement.**

The measurement came first. A join of every `~/.claude/projects/*/*.jsonl`
tool_result back to the tool_use that drew it — the only way to tell a firing
from a transcript that merely printed the guard's source:

| Policy | Genuine blocks | Read |
|---|---|---|
| `guard-destructive` | ~8, across 2 projects | Real catches in `mailstation`. Earns its keep. |
| `genome-guard` | 14, all in colloid | Every one is "the orchestrator forgot the stamp". |
| `grader-lock` | 0 since wiring | Both textual hits are self-reference. |

Against **165** `Task`/`Agent` dispatches in colloid's transcripts, **1** carried
a genome stamp. The layer blocked fourteen times and delivered once, because a
gate can only reject a dispatch that omitted the treatment — it cannot apply it.

So `genome-guard.sh` and its lib module are gone, and `genome-inject.sh` is the
whole layer. Codex and Kimi lose their only genome path with it: both wired the
guard on `PreToolUse` and neither wires the injector. Restoring them means
riding Kimi's `SubagentStart` (≥ 0.29) and Codex's own — both breadcrumbed, both
needing payload-shape verification.

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

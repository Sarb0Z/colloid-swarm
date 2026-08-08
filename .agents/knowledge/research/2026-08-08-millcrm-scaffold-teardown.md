---
date: 2026-08-08
subject: The agent scaffold vendored in Softaims/millcrm — a third-party Rails scaffold plus GitHub spec-kit, what it does better than this repository, and what it proves about scaffold rot
kind: research
source: ~/Projects/FlourCRM/millcrm (git HEAD 53f4752, read directly 2026-08-08) · https://github.com/Softaims/millcrm · https://code.claude.com/docs/en/memory · https://code.claude.com/docs/en/sub-agents
---

# millcrm scaffold teardown

`millcrm` is a Rails 8 + Inertia/React flour-distribution POS that sits beside
`automata-pos` under `~/Projects/FlourCRM/`. Its sibling carries the colloid
scaffold. `millcrm` does not. It carries a different one, and that scaffold is
good enough to learn from.

This entry records another repository's scaffold. Delete it and no one can
rebuild it from this tree.

## Provenance

| Claim | Grade |
|---|---|
| Initial commit `24c1416` holds 479 files, authored by `umar482 <badarvlog@gmail.com>`, 2026-08-06 | `[P]` read the commit |
| 165 of those 479 are `.claude/` + `.specify/` — the scaffold arrived with the repository | `[P]` measured |
| The operator (`Sarb0z`) takes over at `0c775ec`, the third commit | `[P]` read the log |
| `.claude/settings.json` sets `statusLine.command` to `/Users/dev_umar/Downloads/Projectss/Clients/POC/statusline/statusline.sh` | `[P]` read the file |
| That path does not exist on this machine, so the statusline is dead | `[P]` `ls` returns no such file |
| Spec workflow is GitHub spec-kit `0.4.3` (`.specify/init-options.json`) | `[P]` read the file |

The scaffold is inherited, not chosen. Every defect below traces to that one
fact: nothing in it was ever re-aimed at this repository.

## What it does better than colloid

**Path-scoped domain rules.** `.claude/rules/` holds 15 files; 11 carry `paths:`
frontmatter scoping them to `app/services/**/*.rb`, `app/models/**/*.rb`,
`spec/**/*.rb` and similar `[P]`. They fire when an agent writes product code.
Colloid's 14 rules are all symlinks to skill `AGENTS.md` files, all scoped to
`.agents/skills/<name>/**` — they fire when an agent edits the scaffold `[P]`.
Both use the documented feature; they aim it at different trees.

**Subagent frontmatter.** The Claude Code documentation lists 16 supported
fields `[P]`. millcrm's 19 agents use 7: `name`, `description`, `tools`,
`model`, `maxTurns`, `permissionMode`, `memory` `[P]`. Colloid's 2 agents use 3,
and `sync-claude-agents.sh:125-127` can emit no others `[P]`. `tools:` is an
enforcement boundary and `memory: project` gives a cell persistent storage at
`.claude/agent-memory/<name>/`; colloid has neither.

**Thresholds a reviewer can measure.** `anti-patterns.md` sets God Model at
~200 lines, STI abuse at 20% subtype-specific columns, Kitchen Sink Concern at
~30 lines; `principles.md` sets extraction at 5+ implementations `[P]`. Compare
`.agents/playbooks/hostile-review.md`: 168 lines, zero numeric thresholds `[P]`.

**Density.** `services.md` is 9 lines and every line is a constraint —
`Data.define(:success, :data, :error)`, never raise for business failures, wrap
multi-model work in a transaction `[P]`. `database-reviewer.md` credits its
source (Supabase's postgres-best-practices) and carries real content: SKIP
LOCKED for queues, cursor pagination over OFFSET, equality-before-range
composite index ordering `[P]`.

**Hygiene.** 20 of 20 skill directories hold a valid `SKILL.md` `[P]`.

## Where it converges with colloid, independently

Four convergences, different author, different stack, no shared lineage `[P]`:

- `principles.md` reaches KISS, DRY-as-knowledge, YAGNI, no-premature-
  abstraction and explicit-over-implicit. "Three similar lines are better than a
  premature abstraction" appears near-verbatim in both repositories.
- The `behavioral-guidelines` skill says "If you notice unrelated dead code,
  mention it — don't delete it". That is colloid's discovered-subprojects
  triage.
- The same skill says "If multiple interpretations exist, present them — don't
  pick silently".
- `caveman.md` suspends its terse mode for security warnings and destructive-
  operation confirmations specifically.

Convergence at four separate points is evidence that these are attractors for
agent scaffolds, not colloid idiosyncrasies.

## What is broken, and the single cause

| Defect | Evidence |
|---|---|
| Statusline points at another machine | `[P]` path absent |
| Copilot sync has never run | `[P]` `.github/instructions/` does not exist |
| Codex sync has never run | `[P]` `.agents/skills/` does not exist |
| ~15 files target absent frameworks | `[P]` `turbo-agent`, `stimulus-agent`, `viewcomponent-agent`, `solid-queue-setup`, `action-cable-patterns` — the repository's own `AGENTS.md` states there is no Hotwire, no ViewComponent, no Solid Queue or Cable |
| Always-on CLI reference contradicts `AGENTS.md` | `[P]` `cli.md` carries no `paths:`, so it loads every session with port 3000 and `bundle exec rspec`; `AGENTS.md` specifies port 3002 and `bin/rspec` |
| 8,580 bytes of rules load unconditionally | `[P]` `caveman.md`, `cli.md`, `cli-tools.md`, `principles.md` carry no `paths:` |

Every one is an act not taken. The scaffold is doing what it was built to do,
at a repository it was not built for.

## The namespace collision

`scripts/sync_claude_skills_to_codex.sh:8-9` sets `SOURCE_DIR=.claude/skills`
and `TARGET_DIR=.agents/skills` `[P]`. Colloid runs the reverse:
`.agents/skills/<name>/SKILL.md` is canonical and `.claude/skills/<name>` is a
symlink into it `[P]`. Two scaffolds claim the same two directories with
opposite ownership. A transplant into `millcrm` must delete that script first,
or the next run of either sync overwrites the other's source.

## What transfers, and what must not

Transfers: path-scoped **domain** rules; the fuller subagent frontmatter set;
numeric thresholds in the standard an author reads while writing; the
carve-out list in `caveman.md`, which is a routing table (compress by default,
expand at named boundaries) rather than a style guide.

Must not transfer: the 19 layer-specific agents — that decomposition is where
this scaffold's rot concentrated, and colloid's two-cells-plus-skills model is a
deliberate YAGNI call. Nor spec-kit, which would give colloid a second workflow
spine beside its playbooks.

## The lesson about rot

The rot sits exactly where the scaffold had no generator. `millcrm` committed
two sync scripts and never ran either `[P]`. Colloid generates `.claude/` from
`.agents/` and `--check` fails when the generated tree drifts `[P]`. The lesson
is not "have a generator" — `millcrm` had two. It is **gate on running it**.

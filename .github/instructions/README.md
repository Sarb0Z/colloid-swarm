# Instruction Files — Scope Contract

This directory is the Copilot fan-out. Every `*.instructions.md` entry here is
a **symlink** to the canonical `AGENTS.md` file that owns the content. GitHub
Copilot follows the symlink, reads the `applyTo` frontmatter, and injects the
content when its globs match edited files.

**Always edit the canonical file, never the symlink.**

## Canonical Hierarchy

Scoped instructions are co-located with the code they govern:

| Scope | Canonical |
| --- | --- |
| Repo-wide behavior | `AGENTS.md` (root) |
| Agent scaffold | `.agents/AGENTS.md` |
| Claude adapter layer | `.claude/AGENTS.md` |
| Demo | `demo/AGENTS.md` |
| Tensium trial | `tensium-trial/AGENTS.md` |
| Skill (feature) | `.agents/skills/<name>/AGENTS.md` |

Skills: `frontend-design`, `panspermia-mutation`, `pentesting`, `perf-budget`,
`search-and-cite`, `security-audit`, `security-scan`, `seo-geo-growth-audit`,
`thermo-nuclear-code-quality-review`.

## Tool Fan-Out

| Tool | Mechanism |
| --- | --- |
| GitHub Copilot | `.github/instructions/*.instructions.md` symlinks → canonical; scoped by `applyTo` |
| Claude Code | layer `CLAUDE.md` symlinks → sibling `AGENTS.md` (lazy nested loading); `.claude/rules/*.md` symlinks → skill canonicals; scoped by `paths` |
| Codex / Kimi | read `AGENTS.md` natively; root `AGENTS.md` directs them to subtree files |

## Dual Frontmatter (Load-Bearing)

Every canonical scoped file starts with both keys over the same globs:

```markdown
---
applyTo: '.agents/skills/security-scan/**,.claude/skills/security-scan/**'
paths:
  - '.agents/skills/security-scan/**'
  - '.claude/skills/security-scan/**'
---
```

Copilot reads `applyTo`. Claude Code reads `paths`. Codex and Kimi treat the
block as inert text. Both keys must stay in sync. Do not remove one of them.

## Skeleton Template

Start a new scoped file from this shape:

```markdown
---
applyTo: '<glob>,<glob>'
paths:
  - '<glob>'
  - '<glob>'
---

# <Scope> Rules

## Business Invariants
- <rule, or "None recorded yet.">

## Abnormal Cases and Rationale
- <rule, or "None recorded yet.">

## Out of Scope
- <rule, or "None recorded yet.">
```

## Content Rules (Mandatory)

1. Document invariants, constraints, lifecycle rules, and policy boundaries.
2. Document abnormal behavior only when it is non-obvious and affects correctness.
3. Use explicit technical English. Follow the ASD-STE100 rules in root `AGENTS.md`.
4. Do not restate what code, `SKILL.md`, or config already says.
5. Keep scope inside the frontmatter glob boundary.
6. Keep empty sections as `None recorded yet.` — filler is prohibited.

## Patterns and Anti-Patterns

Add a pattern only when the same mistake recurs across agent runs or reviews.
Give one precise rule. Explain why the rule exists. Do not add examples unless
the rule repeatedly fails in practice.

## Layering

- Root `AGENTS.md` defines repository-wide behavior and quality expectations.
- Module `AGENTS.md` files define local invariants for their subtree.
- Skill `AGENTS.md` files govern *editing* the skill; `SKILL.md` governs *using* it.

If instructions conflict, prefer the most specific scoped rule. Then reconcile
the conflict at the source document.

## Adding or Moving Instructions

1. Identify the smallest subtree that owns the rule.
2. Add the rule to that canonical file. Extend both frontmatter keys if a new
   path class is covered.
3. A new canonical file needs its fan-out: a symlink here, a `.claude/rules/`
   symlink for skills, and a sibling `CLAUDE.md` symlink for layer directories.

## Maintenance Checklist

- Remove stale guidance when behavior changes.
- Validate frontmatter globs against the real tree when renaming directories.
- Windows contributors need `git config core.symlinks true` (and Developer
  Mode) for the symlink fan-out to materialize.

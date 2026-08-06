---
date: 2026-08-06
subject: How published scaffolds structure a repository knowledge base for coding agents
kind: research
source: https://github.com/github/spec-kit/blob/main/spec-driven.md
---

## Scope note

Thin, and deliberately marked so. Three web searches; **no primary page was
opened in full**. Every claim below is graded against search-result synthesis,
which means the ceiling is `[S]` and several are `[?]`. The two numbers that
look most quotable are the least verified — see "Could not verify".

Enough to decide a scaffold question. Not enough to cite in an argument.

## The pattern as published

A widely-circulated reference layout puts the knowledge base under `docs/`:
`constitution/` (principles, glossary, decision records), `competitors/{rival}/`,
`specs/{module}/{feature}/` with six fixed files per feature, `state/`
(`state.yaml`, backlog, `learnings.yaml`), `episodic/meetings/`,
`identity/agents/`, plus `changes/` and `archive/` at the root.

| Claim | Grade |
|---|---|
| GitHub Spec Kit introduces `constitution.md` defining principles and governance that all agents validate specs against | `[S]` |
| Spec Kit's workflow is constitution → spec → plan → tasks, with templates under `.specify/` | `[S]` |
| `episodic/meetings/` in these layouts means agent-generated nightly notes, not human meeting minutes | `[S]` — inferred from the "nightly notes" annotation and the session-capture pattern below |
| The session-capture pattern is a Stop hook that extracts decisions and lessons into a daily log, later compiled into cross-referenced articles retrieved through an index file rather than a vector store | `[S]` |
| Claude Code memory is commonly modelled as working / episodic / procedural | `[S]` |

## What argues against it

The staleness critique is consistent across the 2026 write-ups and is the
finding that matters:

- A spec written, approved, and never re-checked against running software
  becomes exactly the stale document the practice was meant to replace. `[S]`
- Reported SDD pain points are duplicate specs acting as forked policy, and
  bloated auto-generated agent files accumulating unreviewed policy. `[S]`
- The mitigation named is a continuous verification loop — contract testing and
  drift detection against the running system. `[S]`
- SDD is described as worth it for complex or integration-heavy work, and not
  worth it for exploratory work where requirements are still moving. `[S]`

The load-bearing conclusion: the value attributed to the spec tree depends on a
verification loop, and the loop is the expensive half. A layout diagram shows
the cheap half.

## What transfers

The **index-not-folder** rule transfers cleanly and costs nothing: entries are
long, an index line is short, and retrieval through a plain index file is
reported as sufficient without a vector store.

The **six-file feature template** does not transfer. A fixed schema across
variable features guarantees empty headings, and this scaffold's own
`market-researcher` skill already names an empty heading as the condition under
which a model writes something plausible instead of nothing.

Slots that duplicate machinery already present are not worth a second
implementation: `constitution/principles.md` against path-scoped `AGENTS.md`,
`identity/agents/` against `personas/`, `state/backlog/` against
`breadcrumbs.md`, and `changes/` + `archive/` against git itself.

## Could not verify

- **"150–200 standing instructions before compliance degrades."** Repeated as a
  2026 consensus figure with no primary source, no model named, and no method.
  Folklore until a benchmark is produced. Do not quote it.
- **"Error reductions on the order of tens of percent from refined specs."**
  Attributed to GitHub and AWS early-adopter reports; neither report was
  located, and the range is too wide to act on. `[?]`
- Whether any team runs the drift-detection loop in practice, or whether it is
  only recommended. Nothing found either way.
- The origin layout's own provenance. The artifact was not readable.

## Sources

- https://github.com/github/spec-kit/blob/main/spec-driven.md — Spec Kit's own method document
- https://developer.microsoft.com/blog/spec-driven-development-spec-kit/ — Microsoft walkthrough of the constitution/spec/plan/tasks flow
- https://zeroshot.ghost.io/spec-driven-development-with-ai-coding-agents/ — 2026 practitioner assessment; source of the staleness critique
- https://github.com/coleam00/claude-memory-compiler — hook-driven session capture compiled into an indexed article set
- https://alexop.dev/posts/four-types-memory-coding-agents-claude-code/ — the working/episodic/procedural framing
- https://arxiv.org/pdf/2606.04967 — process taxonomy of frameworks supporting AI software-development agents; not read, listed as the one peer-reviewed lead worth chasing

Coverage: three search passes, no page opened in full. Anything built on this
should re-read the primaries first.

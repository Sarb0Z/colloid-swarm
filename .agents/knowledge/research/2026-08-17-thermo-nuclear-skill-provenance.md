---
date: 2026-08-17
subject: Provenance and upstream state of the vendored thermo-nuclear-code-quality-review skill — Cursor attribution confirmed, one frontmatter delta, no upstream content changes, repetition question unresolved by the vendor
kind: research
source: see `## Sources` — each line carries the URL and how deeply it was read
---

# Thermo-nuclear skill provenance

The vendored `thermo-nuclear-code-quality-review` skill's attribution and
upstream state were checked before deciding whether to consolidate its
repeated rule statements. The decision: do not consolidate — keep byte-parity
with an actively-shipped upstream.

## Scope note

**Solid.** The attribution, dates, and content-parity claims — two independent
primary sources (repo commits, team-member post) agree.

**Thin.** Reception claims rest on one credible practitioner review each. The
"repetition is deliberate reinforcement" framing has no source either way.

## Claims

| Claim | Grade |
|---|---|
| The skill is Cursor's: `cursor/plugins` repo, `cursor-team-kit` plugin, MIT, first commit `909bc5d` dated 2026-05-21 by ericzakariasson + cursoragent | `[P]` |
| "Most used skill internally at Cursor" is Zakariasson's own statement, same day, on X | `[P]` — self-reported, unaudited |
| Upstream body text is unchanged since first publication; our vendored copy matches byte-for-byte | `[P]` — fetched and compared 2026-08-17 |
| Upstream frontmatter carries `disable-model-invocation: true` since day one; our copy lacked it until 2026-08-17 | `[P]` |
| Cursor has published no rationale for the six-way repetition of the same ~7 rules across sections; no tuning or performance guidance exists | `[?]` — absence claim, scoped to repo README/CHANGELOG/commits, marketplace page, and targeted searches |
| One credible independent live test (Pocock, 2026-05-28) found ~5 of 7 findings useful, flags false-positive ambition, no testing/seams coverage, and calls the prompt "repetitive and could be condensed significantly" | `[S]` — single source |
| Companions exist, not successors: `thermo-nuclear-review` (security/correctness rubric) and `thermos` (orchestrator running both in parallel), both in the `thermos` plugin since 2026-05-28 | `[P]` |

## Decision this informed

Consolidating the repetition was declined 2026-08-17: upstream ships it
verbatim, no vendor guidance recommends condensing, and a local rewrite
orphans the copy from upstream updates. The one adopted delta is the
`disable-model-invocation: true` frontmatter, restoring upstream's
explicit-invocation-only routing. The companion skills are unadopted; adopting
`thermo-nuclear-review`/`thermos` is a separate scope decision.

## Sources

- https://github.com/cursor/plugins/blob/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review/SKILL.md — fetched, diffed against vendored copy
- https://github.com/cursor/plugins/commits/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review/SKILL.md — commit history read
- https://x.com/ericzakariasson/status/2057521364622553442 — read (2026-05-21 post)
- https://github.com/cursor/plugins/commit/5080d38e4c522a96349824ba8adab4cac5a0ec22 — read (Thermos relocation)
- https://github.com/cursor/plugins/commit/6e3d2ea56d7d446b955eaae6ac4c8eef8bf504cf — read (restore to team-kit)
- https://raw.githubusercontent.com/cursor/plugins/main/thermos/README.md — read
- https://raw.githubusercontent.com/cursor/plugins/main/thermos/skills/thermo-nuclear-review/SKILL.md — read
- https://cursor.com/marketplace/skills/thermo-nuclear-code-quality-review — read
- https://daily.dev/posts/can-cursor-s-hardcore-review-skill-stop-the-slop--sjkerp9tv — read (Pocock live test, 2026-05-28)
- https://x.com/jimmykoppel/status/2064108802610463091 — read; promotional, low weight

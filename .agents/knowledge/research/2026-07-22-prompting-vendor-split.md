---
date: 2026-07-22
subject: Mid-2026 vendor prompting guidance — chain-of-thought and few-shot split by vendor; negation and pressure density is what both flag
kind: research
source: https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices
---

## Scope note

Five researcher cells over primary vendor documentation and one paper, run for a
scaffold prompt-pattern audit. The audit's named hypothesis was "chain-of-thought
and few-shot are detrimental now"; the finding that mattered was adjacent to it.

## Findings

| Claim | Grade |
|---|---|
| OpenAI discourages "think step by step" for reasoning models: "unnecessary… can sometimes hinder" | `[P]` |
| Anthropic keeps chain-of-thought only as a fallback when extended thinking is off, and prefers general instructions over prescriptive steps when it is on | `[P]` |
| Kimi's guide still recommends step decomposition | `[P]` |
| Wharton R2 (arXiv 2506.07142): negligible accuracy gain from chain-of-thought on reasoning models, with 20–80% more tokens and time | `[P]` |
| Few-shot: OpenAI says zero-shot first; Anthropic still headline-recommends it (it works inside thinking blocks); Kimi recommends it | `[P]` |
| Few-shot degrades open-ended reasoning because the model mimics example structure, but still helps format-locking, classification, extraction, and smaller models | `[S]` |
| Both major vendors flag aggressive anti-laziness pressure and negation-dense instructions: newer models over-trigger on them (Anthropic migration guide) and burn reasoning tokens reconciling contradictions (OpenAI GPT-5 guide); Cursor's "be THOROUGH" reported counterproductive | `[P]` |
| No independent replication of any of this on 2026-generation models | `[A]` |
| Kimi lineage is K2 → K2.5 → K2.6 → K3 (thinking always on); there is no "K2.7". GLM-5.2 auto-decides thinking | `[S]` |

## What it changed here

The scaffold held no true few-shot pairs and near-zero literal chain-of-thought.
Its exposure was emphasis and negation density in the skills layer and the
stakes framing in `AGENTS.md`. The named patterns were the starting hypothesis,
not the scope; the adjacent sweep found the real exposure.

## Sources

- https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices
- https://developers.openai.com/api/docs/guides/reasoning-best-practices
- https://developers.openai.com/api/docs/guides/prompt-guidance
- https://platform.kimi.ai/docs/guide/prompt-best-practice
- https://docs.z.ai/guides/overview/migrate-to-glm-new.md
- https://arxiv.org/abs/2506.07142

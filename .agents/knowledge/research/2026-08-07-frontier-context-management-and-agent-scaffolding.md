---
date: 2026-08-07
subject: Frontier practice for agent context management, instruction files, skills, hooks, and persona prompting
kind: research
source: https://code.claude.com/docs/en/hooks
---

## Scope note

Twenty sources reviewed, eighteen kept. Vendor documentation was read directly;
the four empirical claims that carry weight (`NoLiMa`, `Chroma`, `PRISM`,
`Zheng et al.`) come from the papers, not from summaries of them. The hook and
skill field inventories were re-verified a second time against the primary doc
by the dispatching session, because a scaffold rewrite turns on them.

Two widely-quoted numbers did **not** survive the search and are marked `[?]`
below. Treat this entry as sufficient to decide a scaffold question, and
insufficient to quote as settled science.

## Context engineering doctrine

Anthropic frames context as a finite **attention budget** that every token
depletes, and states the goal as "the smallest set of high-signal tokens that
maximize the likelihood of your desired outcome". Four named techniques:
compaction (summarize and reinitialize), tool-result clearing (described as
"the safest lightest touch form of compaction"), structured note-taking to a
file outside the window, and sub-agent isolation where a subagent burns tens of
thousands of tokens and returns 1,000-2,000 tokens of distilled summary.

Retrieval guidance is explicitly hybrid rather than purist: Claude Code "naively
drops CLAUDE.md into context up front" while glob and grep fetch files
just-in-time.

| Claim | Grade |
|---|---|
| Memory tool plus context editing yields +39% task success; context editing alone +29%; a 100-turn web-search eval completed with 84% fewer tokens | `[P]` vendor-internal evals, no external replication |
| Tool-result clearing defaults: trigger at 30,000 input tokens, keep 3 tool uses, clear at least 5,000 | `[P]` |
| Server-side compaction (beta `compact-2026-01-12`) defaults to a 150,000-token trigger, 50,000 floor | `[P]` |
| Naive observation masking matches or slightly exceeds LLM summarization on SWE-bench Verified at half the cost | `[S]` arXiv 2508.21433 v3, NeurIPS'25 DL4C — directly undercuts "summarize first" |

## Context rot

Degradation with input length is robust across 18 models (Chroma) and 13 models
(NoLiMa), and appears **even when task complexity is held constant**.

| Claim | Grade |
|---|---|
| At 32K tokens, 11 of 13 models fall below 50% of their short-context baseline; GPT-4o drops 99.3% to 69.7% | `[P]` NoLiMa, arXiv 2502.05167, ICML 2025 |
| Needle **position** showed no notable effect — "lost in the middle" is not the mechanism here | `[P]` Chroma |
| Structurally **coherent** haystacks scored consistently *worse* than shuffled ones, across all 18 models | `[P]` Chroma — a well-organized instruction file is not automatically easier to retrieve from |
| Claude models specifically fail by abstaining under ambiguity rather than hallucinating | `[P]` Chroma |
| "60-70% of nominal context is effectively usable"; "degradation starts at 300-400K on 1M models"; "assume 50% as a safe threshold" | `[?]` **no primary source located.** Traces only to 2026 vendor blogs citing each other. Chroma and NoLiMa publish curves, not a utilization fraction. Use the measured 32K anchor instead. |

## Instruction files

| Claim | Grade |
|---|---|
| Target is under 200 lines per `CLAUDE.md`; "longer files consume more context and reduce adherence" | `[P]` for the target being stated; `[?]` for the causal claim — asserted in vendor docs, no ablation or eval published |
| `CLAUDE.md` is delivered as a **user message after the system prompt**, is "context, not enforced configuration", with "no guarantee of strict compliance, especially for vague or conflicting instructions" | `[P]` |
| Where two rules contradict, "Claude may pick one arbitrarily" | `[P]` — makes internal contradiction a correctness bug, not a style issue |
| Block-level HTML comments are stripped before injection, so they cost zero tokens | `[P]` |
| `AGENTS.md` is a real cross-vendor convention: 60k+ repositories, stewarded by the Agentic AI Foundation under the Linux Foundation, adopted by Codex, Amp, Jules, Cursor, Factory | `[P]` — the 60k figure links to a live GitHub code search, so it is self-verifying |
| The `CLAUDE.md` to `AGENTS.md` symlink is explicitly blessed as the alternative to an `@AGENTS.md` import | `[P]` |

## Agent Skills

The **portable** spec is exactly six fields: `name`, `description`, `license`,
`compatibility`, `metadata`, `allowed-tools`. Anything else hard-errors on
upload to claude.ai or the Skills API.

Claude Code accepts a much larger superset: `when_to_use`,
`disable-model-invocation`, `user-invocable`, `disallowed-tools`, `model`,
`effort`, `context: fork` with `agent` and `background`, `hooks`, `paths`,
`argument-hint`, `arguments`, `shell`, `once`.

| Claim | Grade |
|---|---|
| Limits: `name` <= 64 chars, `description` <= 1,024 chars and third person, body under 500 lines, reference files one level deep, `## Contents` required past 100 lines | `[P]` |
| The skill **listing** truncates `description` plus `when_to_use` at 1,536 chars combined | `[P]` |
| After compaction, invoked skill bodies are re-injected capped at **5,000 tokens per skill and 25,000 total**, oldest dropped first, truncation **keeping the start of the file** | `[P]` — so the most important instructions must sit at the top of a `SKILL.md` |

## Hooks

The event set is now roughly 31 events. Confirmed present and relevant:
`SubagentStart`, `SubagentStop`, `SessionEnd`, `PostCompact`,
`PostToolUseFailure`, `PostToolBatch`, `InstructionsLoaded`, `FileChanged`,
`Setup`, `UserPromptExpansion`, `PermissionRequest`, `PermissionDenied`,
`TeammateIdle`, `Elicitation`.

| Claim | Grade |
|---|---|
| `SubagentStart` accepts `hookSpecificOutput.additionalContext`, delivered "at the start of the conversation, before the first prompt", and it lands "in the subagent's own transcript, not in the parent conversation" | `[P]` verified twice against the primary doc |
| `PreToolUse` accepts `hookSpecificOutput.updatedInput`, which "replaces a tool's arguments before it runs" | `[P]` |
| `PreCompact` **cannot** inject context and can only block; `PostCompact` has no decision control either | `[P]` — routing post-compaction restatement through `SessionStart` with `source=compact` is the only lever that works |
| Plain stdout reaches the model on only three events: `SessionStart`, `UserPromptSubmit`, `UserPromptExpansion` | `[P]` |
| `asyncRewake` runs a command hook in the background and wakes Claude on exit 2, surfacing stderr as a system reminder | `[P]` |
| Timeouts: 600s default for command/http/mcp_tool, 30s for prompt, 60s for agent; `UserPromptSubmit` lowers the command default to 30s and a timeout there **discards output silently**; `SessionEnd` shares a 1.5s budget | `[P]` |
| All hook output strings cap at 10,000 characters | `[P]` |
| Matchers containing only `[A-Za-z0-9_,| -]` are compared as **exact strings**, not regexes | `[P]` — a bare `mcp__playwright` prefix matches nothing |
| Hook types beyond `command`: `http`, `mcp_tool`, `prompt`, `agent` | `[P]` |

## Multi-agent orchestration

| Claim | Grade |
|---|---|
| Opus 4 lead with Sonnet 4 subagents beat single-agent Opus 4 by 90.2% on an internal research eval | `[P]` vendor-internal, unreplicated |
| On BrowseComp, token usage alone explains 80% of performance variance; three factors explain 95% | `[P]` — a browsing benchmark; do not carry to coding |
| Agents use ~4x chat tokens; multi-agent ~15x | `[P]` vendor-internal |
| "Most coding tasks involve fewer truly parallelizable tasks than research" | `[P]` — an explicit scope limit on fan-out |
| Named failure modes: over-spawning for trivial queries, duplicate work from vague task descriptions, synchronous bottlenecks, emergent sensitivity where small lead-prompt changes unpredictably alter subagent behavior | `[P]` |
| Mitigation that worked: explicit effort-scaling rules in the prompt (1 agent / 3-10 calls for fact-finding; 2-4 subagents for comparisons; 10+ only for complex research) | `[P]` |

## Persona and role prompting

The hostile question was whether injecting a personality into every subagent is
supported by evidence. It is not.

| Claim | Grade |
|---|---|
| 162 roles x 4 model families x 2,410 factual questions: personas in system prompts do **not** improve performance versus no persona; per-persona effects are "largely random"; automatic persona selection performs no better than random | `[P]` Zheng et al., Findings of EMNLP 2024 |
| Expert personas improve alignment but **damage accuracy**; the study specifically models prompt length and placement as moderators | `[P]` Hu et al., PRISM, arXiv 2603.18507, 2026-03-19 |
| Persona prompting *does* reliably shift tone, style, output diversity, and human-preference alignment | `[S]` |
| Anthropic's multi-agent guidance uses **role** prompts — objective, output format, tool guidance, boundaries | `[P]` — note this is task scoping, not personality |

Nothing located supports injecting an adversarial *temperament* as an accuracy
intervention. The defensible reading is generative diversity for a
selection loop, which is a different claim and is untested here.

## Bearing on this scaffold

Stated as observations, not as a work plan. The work items are one line each in
`breadcrumbs.md`.

- A hook **can** now inject context into a spawned subagent. Any design premised
  on it being impossible is working from a stale fact.
- `PreCompact` genuinely cannot inject. A design that routes post-compaction
  restatement through `SessionStart` is correct and should not change.
- Deferring MCP tool schemas targets the "bloated tool sets, ambiguous decision
  points" failure mode named in the vendor's own list.
- A hand-rolled note store (queue plus tradeoff log plus dated observations) is
  an implementation of "structured note-taking", one of the three named
  long-horizon techniques.
- Unconditional review fan-out has no ceiling in the guidance; the guidance
  supplies effort tiers precisely because agents judge effort badly.

## Could not verify

- Any measured "usable fraction of the context window". Three primary reports
  publish curves, not fractions.
- Any measurement behind "longer instruction files reduce adherence". Vendor
  assertion only. Direction is plausible and consistent with the context-rot
  results; the 200-line threshold is a heuristic, not a result.
- Publication dates on three vendor engineering pages, which carry no date
  field. Secondary reporting of those dates was not treated as primary.
- Whether adversarial-temperament prompting helps **review** quality
  specifically. The literature tests factual and discriminative tasks.
  `fixtures/review-episodes/` is the instrument that would answer it locally.

## Sources

- https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents — attention budget, compaction, note-taking, sub-agents
- https://claude.com/blog/context-management — 2025-09-29; the 39% / 29% / 84% internal-eval numbers
- https://platform.claude.com/docs/en/build-with-claude/context-editing.md — tool-result clearing config and defaults
- https://platform.claude.com/docs/en/build-with-claude/compaction.md — server-side compaction, 150K trigger
- https://research.trychroma.com/context-rot — 18-model controlled study; position had no effect, structure did
- https://arxiv.org/abs/2502.05167 — NoLiMa (ICML 2025); the 32K / 11-of-13 / sub-50% ceiling
- https://arxiv.org/abs/2602.07962 — LOCA-bench (2026-02-08); context rot measured on agents plus scaffolds
- https://arxiv.org/abs/2508.21433 — observation masking matches LLM summarization at half the cost
- https://code.claude.com/docs/en/memory — 200-line target, rules, compliance caveats
- https://code.claude.com/docs/en/context-window — what survives compaction; skill re-injection caps
- https://code.claude.com/docs/en/hooks — event reference, exit codes, JSON fields, timeouts, hook types
- https://code.claude.com/docs/en/skills — full frontmatter table and the six-field portable spec
- https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices.md — limits, progressive disclosure, eval-first authoring
- https://code.claude.com/docs/en/sub-agents — context isolation, `--append-subagent-system-prompt`, subagent `memory:`
- https://code.claude.com/docs/en/mcp.md — `ENABLE_TOOL_SEARCH` values and the `auto:N` threshold semantics
- https://www.anthropic.com/engineering/multi-agent-research-system — 90.2%, 80%-of-variance, 4x/15x, failure modes
- https://agents.md/ — the cross-vendor convention, 60k repositories, AAIF stewardship
- https://aclanthology.org/2024.findings-emnlp.888/ — personas do not improve objective performance
- https://arxiv.org/abs/2603.18507 — expert personas improve alignment, damage accuracy

---
date: 2026-08-21
subject: What vendors and controlled studies say instruction files, hooks, subagents, tool count, and verification loops do to frontier coding-agent performance — and which of this scaffold's bets each finding supports or undercuts
kind: research
source: see `## Sources` — each line carries the URL and how deeply it was read
---

# Scaffold effects on frontier coding agents

Dispatched to answer "is our scaffold the kind that raises coding performance,
or the kind that just feels rigorous?" The short answer: hooks, subagent
isolation, fresh-context review and external notes are supported; instruction
files buy cost and latency, not correctness; in-session decay is the measured
degradation mode nobody's file structure fixes.

## Scope note

**Solid.** Anthropic's context-engineering and Claude Code best-practice docs,
OpenAI's GPT-5 prompting guide and Codex best-practices page, MAST (NeurIPS
2025), and the three 2026 instruction-file studies — each read directly.

**Thin.** OpenAI's GPT-5.6 guide (reached only through trade press; the
cookbook URL still serves the GPT-5 text). Google's Antigravity transition
(trade press only). The tool-count degradation curves and the SWE-bench
self-verification statistic came from search aggregation; only one tool-count
paper was opened.

**Absent.** No source quantifies hook latency or false-block rates in
production. That cost is ours to measure.

## Claims

Grades: `[P]` primary read directly · `[S]` secondary · `[?]` unverified ·
`[A]` our own analysis.

### Instruction files

- `[P]` A controlled ablation (Claude Code + Codex, 17 repo tasks, 288 runs,
  gold tests) found the AGENTS.md/CLAUDE.md injection strategy does not move
  correctness on either agent; equivalence-bounded at ≤10–15 pp. Failures
  traced to implementation choices, not missing repo knowledge. (2607.27250)
- `[P]` A factorial study of file size, instruction position, file
  architecture and cross-file contradiction (1,650 sessions, 16,050
  function-level observations, Sonnet 4.6 / Opus 4.6–4.7) found none of the
  four moves adherence after correction (BF10 0.05–0.10). The one detected
  effect is within-session decay: ~5.6% lower odds of compliance per
  additional generated function (OR 0.944). (2605.10039)
- `[P]` Across 124 real PRs in 10 repos, AGENTS.md presence associated with
  28.64% lower median runtime and 16.58% fewer output tokens at comparable
  completion. Observational, not randomized. (2601.20404)
- `[P]` Anthropic names "the over-specified CLAUDE.md" as a failure pattern —
  "Claude ignores half of it because important rules get lost in the noise" —
  and gives the pruning test: would removing this line cause a mistake? If
  not, cut it. Hooks are deterministic; CLAUDE.md is advisory. (best-practices)
- `[P]` OpenAI's Codex guidance: keep AGENTS.md short, add rules only after
  observing a repeated mistake, push durable rules into AGENTS.md or skills,
  add MCP tools only when they unlock a real workflow. (codex best-practices)
- `[P]` OpenAI's GPT-5 guide: instruction-precise models pay for contradictory
  or vague prompts in reasoning tokens spent reconciling them; reserve
  always/never for true invariants. (gpt-5 guide)
- `[S]` OpenAI's GPT-5.6 guide reportedly reverses toward outcome-first
  prompts — trim repeated rules, style notes, and process the model already
  handles — with internal coding-agent evals up ~10–15% at 41–66% fewer
  tokens. The guide text was not reached; figures rest on Decrypt.

### Context and session length

- `[P]` Context rot is measured across 18 frontier models well below the
  window limit (Chroma). Anthropic's sanctioned remedies, lightest first:
  compaction, structured note-taking to external files, and subagents that
  burn tens of thousands of tokens but return 1–2k. (context-engineering)
- `[A]` The 5.6%-per-function decay and context rot describe the same
  mechanism from two directions. For this scaffold the implication is that a
  long single-thread run of the six-step workflow is the main predicted
  degradation, not the length of `AGENTS.md`.

### Subagents and multi-agent

- `[P]` Anthropic's orchestrator–worker research system beat a single Opus 4
  by 90.2% on an internal breadth-first research eval; token spend explained
  80% of variance; ~15× the tokens of a chat; explicitly *not* generalized to
  coding. Vague delegation caused duplicated and gapped work until each
  subagent got an objective, output format, tool guidance and boundaries.
  (multi-agent-research-system)
- `[P]` MAST (NeurIPS 2025; 1,600+ traces, 7 frameworks, κ 0.88) finds 14
  failure modes in three clusters — system design, inter-agent misalignment,
  task-verification failure — and attributes most to orchestration design,
  not model weakness. (2503.13657)
- `[S]` On sequential, dependent coding subtasks multi-agent setups degrade up
  to ~70% and cost 4–220× tokens. Effect sizes are from an aggregation; the
  underlying papers were not opened.

### Tools and skills

- `[P]` Anthropic: tool-description refinement alone took Sonnet 3.5 to SOTA
  on SWE-bench Verified; an agent rewriting its own tool descriptions after
  failure analysis cut future completion time 40% in one case; overlapping
  toolsets are "one of the most common failure modes". (writing-tools)
- `[S]` Selection accuracy degrades past roughly 10–15 tools; shortlisting by
  retrieval tripled accuracy (13.62% → 43.13%) while halving prompt tokens in
  one benchmark. One paper opened (2605.24660); the others aggregated.

### Verification

- `[P]` Anthropic's layered design — in-turn check, per-turn goal condition,
  a Stop hook that blocks until a script passes (overridden after 8
  consecutive blocks), and a fresh-context reviewer that sees only the diff
  and criteria — is the vendor's recommendation, and it is this repository's
  shape. (best-practices)
- `[?]` On SWE-Bench Verified, 88.0% of passing-looking runs self-verified,
  and 35.7% of those still shipped a wrong patch. Surfaced by search summary;
  primary paper not identified.
- `[P]` Rollout voting and refine-over-summaries moved Claude 4.5 Opus from
  70.9% → 77.6% on SWE-Bench Verified and 46.9% → 59.1% on Terminal-Bench
  v2.0. Single preprint, unreplicated. (2604.16529)

## What this says about our bets

| Scaffold element | Verdict | Basis |
|---|---|---|
| Hook policies for guards and gates | Right lever; keep | `[P]` hooks deterministic, files advisory |
| `AGENTS.md` at ~2.5k words | Prune by the would-removing-it-cause-a-mistake test; stop tuning it for compliance | `[P]` ×3 null results on structure; efficiency gain only |
| Six-step workflow in one thread | Checkpoint and hand off to fresh contexts on long runs | `[P]` in-session decay, context rot |
| Tiered subagents for investigation, QA, fan-out | Supported; do not fan out sequential single-file edits | `[P]` Anthropic, MAST; `[S]` sequential penalty |
| Hostile review in a fresh reviewer context | Vendor-endorsed as-is; the fresh context is the active ingredient | `[P]` best-practices |
| `qa-verifier` after the implementer's own tests | Keep as the gate; self-verification leaves ~a third wrong | `[?]` self-verification stat |
| 15 skills + MCP surface | Audit for overlap before adding; write skill descriptions as tool descriptions | `[P]` writing-tools; `[S]` tool-count curves |
| breadcrumbs / debt-log / knowledge as external memory | Matches the sanctioned note-taking pattern | `[P]` context-engineering |
| Absolute language | Keep for safety, data loss, publish; sweep it out of style rules | `[P]` gpt-5 guide |
| Rollout voting for high-stakes tasks | Not in the scaffold; candidate only | `[P]` single preprint |

## Sources

- https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents — read in full (2025-09-29)
- https://code.claude.com/docs/en/best-practices — read in full (fetched 2026-08-21)
- https://www.anthropic.com/engineering/writing-tools-for-agents — read in full (2025)
- https://www.anthropic.com/engineering/multi-agent-research-system — read in full (2025)
- https://research.trychroma.com/context-rot — read in full (2025)
- https://developers.openai.com/cookbook/examples/gpt-5/gpt-5_prompting_guide — read in full (2025-08)
- https://developers.openai.com/codex/learn/best-practices — read in full (fetched 2026-08-21)
- https://decrypt.co/373439/openai-new-gpt-5-6-prompt-guide-chatgpt — trade press; the guide it reports was not reached (2026-07-13)
- https://arxiv.org/abs/2607.27250 — abstract and results read (2026-07-28)
- https://arxiv.org/abs/2601.20404 — abstract and results read (2026-01-28, rev. 2026-03-30)
- https://arxiv.org/abs/2605.10039 — abstract and results read (2026-05-11)
- https://arxiv.org/html/2605.24660v1 — partially read; fetch truncated (2026)
- https://arxiv.org/abs/2503.13657 — read (NeurIPS 2025)
- https://arxiv.org/pdf/2604.16529 — abstract and results read (2026-04-16)
- https://virtualizationreview.com/articles/2026/05/19/google-moves-gemini-cli-into-antigravity-cli-as-agent-platform-expands.aspx — trade press (2026-05-19)
- https://medium.com/@mjgmario/single-agent-vs-multi-agent-systems-when-coordination-helps-hurts-and-pays-off-57735ee7916d — secondary aggregation; primaries not opened

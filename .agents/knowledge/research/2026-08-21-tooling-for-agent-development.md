---
date: 2026-08-21
subject: Evidence for tuning lint, format, type and test tooling around LLM coding agents — what vendors say, the one quantitative ablation, and where the style-rule hypothesis stays an inference
kind: research
source: see `## Sources`
---

# Tooling for agent development

The operator's hypothesis: style-only lint rules (import order, quotes, line
length) cost an agent edits and context without catching defects, so they
should be auto-fixed or deleted; defect-catching rules should be kept and
extended, and recurring agent mistakes should become custom rules. The
evidence supports the direction; no study isolates style rules as a variable.

Grades: `[P]` primary read directly · `[S]` secondary · `[?]` unverified · `[A]` our analysis.

## Claims

- `[P]` Anthropic: hooks are deterministic, CLAUDE.md is advisory; code-style
  rules belong in the instruction file only when a formatter cannot enforce
  them; a pass/fail signal the agent can run itself is the highest-leverage
  lever ("the trust-then-verify gap"). (best-practices)
- `[P]` Evil Martians: move a rule into a formatter config or a custom lint
  rule rather than AGENTS.md — "LLMs often forget AGENTS.md instructions, and
  scripts are much more reliable and cheaper in tokens"; auto-fix via a Stop
  hook and pre-commit on changed files only; when the model makes the same
  mistake a few times, have it write a custom ESLint rule. (2026-05-26)
- `[P]` SWE-agent (NeurIPS 2024): a linter wired into the edit action, which
  rejects syntactically invalid edits before they land, raised SWE-bench Lite
  resolve rate from 15.0% to 18.0%; interface design overall accounted for
  10.7 of 12.47 points. The one quantitative result found.
- `[S]` A 2025 survey: compiler-feedback repair rates fall from 81.4% on
  HumanEval to 31–35% on CoderEval and SWE-Bench Verified; self-generated test
  feedback is the stronger correctness signal. (arXiv 2510.12399)
- `[P]` AGENTS.md spec (OpenAI, Amp, Google Jules, Cursor, Factory): canonical
  sections are setup, test, and style commands; agents run listed checks
  before finishing. No guidance on style vs defect rules.
- `[S]` GitLab disabled `import/order` repo-wide and drove allowed warnings
  from ~900 to 0; import-plugin docs say to disable order rules when a sorter
  runs. Pre-agent hygiene, reusable as precedent.
- `[?]` `eslint-plugin-llm-core` targets observed LLM defect patterns (async
  callbacks in array methods, empty catch, `any` catch params) with
  teaching-style messages; its own effectiveness is unvalidated.
- `[A]` This scaffold already auto-fixes style in `post-edit-check.sh` (ruff,
  prettier, eslint --fix), so the remaining work is per-repository: delete
  style-only rules, add defect rules, and convert recurring corrections into
  gates. The mined-corrections entry is the input list.

## Gaps

No controlled experiment isolates "style-only rule removed" as a treatment.
OpenAI and Cursor pages were not opened directly. Google has no located
primary guidance.

## Sources

- https://code.claude.com/docs/en/best-practices — read in full
- https://claude.com/blog/steering-claude-code-skills-hooks-rules-subagents-and-more — read
- https://evilmartians.com/chronicles/stop-writing-rules-in-agents-md-use-agent-hooks-and-nano-staged-instead — read in full (2026-05-26)
- https://agents.md/ — read
- https://arxiv.org/pdf/2405.15793 — SWE-agent, results read (NeurIPS 2024)
- https://arxiv.org/pdf/2510.12399 — survey, partially read (2025)
- https://gitlab.com/gitlab-org/gitlab/-/merge_requests/21129 — read
- https://github.com/import-js/eslint-plugin-import/blob/main/docs/rules/order.md — read
- https://dev.to/pertrai1/i-analyzed-500-ai-coding-mistakes-and-built-an-eslint-plugin-to-catch-them-jme — read (2026-04-04)

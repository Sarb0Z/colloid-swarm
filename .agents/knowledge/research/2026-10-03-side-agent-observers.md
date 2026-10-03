---
date: 2026-10-03
subject: How Claude Code's "You should know" side agent works, and the prior art for observers that watch a coding agent
kind: research
source: see `## Sources`
---

# Side-agent observers

Claude Code 2.1.287 ships "You should know", a built-in mod that runs a side
agent beside the main one and shows the person notes. This entry records how it
works and what products and research say about observers of a coding agent.
Gather the evidence before a colloid mod copies the pattern.

## Claims

Grades: `[P]` primary read directly · `[S]` secondary · `[?]` unverified (seen
in a search summary only) · `[A]` our own measurement or analysis.

### "You should know"

- `[P]` It shipped on 2026-10-01 in 2.1.287: "a built-in mod where a side agent
  watches your back and flags things you or Claude might miss". It is off by
  default and works only "for first-party sessions with telemetry on". A
  2026-10-02 changelog entry says that notes name who made a decision: "we",
  "the main agent" or "you".
- `[P]` The mods overview says it "Runs a side agent that watches your back
  while Claude works on longer tasks. When it finds something worth knowing that
  you might miss, it shows you a note above the prompt."
- `[P]` Its source is not in the public `mods/` folder of `anthropics/claude-code`.
  That folder holds only `agents-md`, `diff`, `sec-default` and `telemetry`.
- `[A]` Strings in the local 2.1.288 binary show these properties:
  - The side agent "shares the conversation context" and is "a completely
    separate instance". It has "NO tools available" and gives a "one-off
    response". The main agent "is NOT interrupted".
  - The side agent's prompt also receives truncated git diffs, its earlier
    suggestions, and the topics the person marked as understood.
  - The telemetry fields include `fork_ms` and `cache_create`. A forked,
    prompt-cached context is an inference from those names. No string states
    it.
- `[A]` Its output contract has these parts:
  - The default is `learn: none`, because "The bar for showing a suggestion is
    very high! When in doubt, default to suggesting nothing".
  - A note carries one of two tags:
    - "You should know" covers a concept or design that "deeply matters for
      their work".
    - "Heads up" covers "a decision Claude made, something it did not highlight,
      or a result that may be off" with "an immediate cost if they miss it".
- `[A]` The note shows above the prompt, never in the transcript. Its options are
  "1: Learn more  2: Know this already  0: Dismiss". After the explainer, the
  options are "1: Understood  2: Chat in main session  0: Dismiss".
- `[A]` No setting tunes its frequency, model or categories. The one environment
  variable is `CLAUDE_CODE_YOU_SHOULD_KNOW_DEBUG`. The trigger, the model, and
  whether the main model sees the notes were not recovered.
- `[A]` It cannot run on this machine as configured. `~/.claude/settings.json`
  sets `DISABLE_TELEMETRY=1`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` and
  `DO_NOT_TRACK=1` for both accounts.

### Observers that gate actions

- `[P]` Claude Code's auto-mode classifier watches each tool call, live, and
  blocks it. It reads user messages and tool calls only. It removes Claude's own
  messages and tool outputs, to resist self-justification and injection. It has
  two stages: a one-token filter, then chain-of-thought on flagged calls only.
  The vendor's figures are these:
  - Real traffic (n=10,000): false-positive rate 0.4% after stage 2.
  - Real overeager actions (n=52): false-negative rate 17% after stage 2.
- `[P]` An independent stress test sent 253 state-changing actions from 128
  ambiguous DevOps prompts. The end-to-end false-negative rate was 81.0%:
  - 36.8% of the actions fell outside the classifier's scope, because in-project
    file edits are auto-approved.
  - On the actions it evaluated, the false-negative rate was 70.3%.
- `[P]` A red-team attacked Auto Mode and Codex Guardian with prompt injection
  aimed at the monitor itself. It ran arbitrary bash in 79% of trials.
- `[P]` Codex auto-review (formerly "guardian") is a subagent that reviews each
  boundary-crossing action. It reads a compact transcript and the request.
  OpenAI calls it "not a deterministic security guarantee". OpenAI publishes no
  precision or recall figures.

### Critics, advisors and reviewers

- `[?]` Google Jules runs a critic on each patch before submission, and the
  critic can trigger a replan. A Planning Critic (2026-01-26) reviews plans.
  Google reports a 9.5% drop in task failures.
- `[P]` The Anthropic advisor tool is pull-based: the agent calls a stronger
  model at decision points. That model has the full transcript and no tools.
- `[P]` Cursor Bugbot reviews pull requests after the fact. Its rules are
  learned from reactions and replies. The vendor reports a 78.13% resolution
  rate across 50,310 pull requests.
- `[?]` GitHub Copilot code review stays silent on 29% of reviews by design and
  cannot block a merge.

### Research

- `[P]` A CoT monitor that reads the reasoning catches reward hacking better
  than a monitor that reads actions only. A weaker monitor can watch a stronger
  agent (Baker et al., 2025-03). Training against the monitor produced
  obfuscation.
- `[?]` Monitors are an attack surface: prompt injection in agent output evades
  diverse monitors (2025-10).
- `[?]` LLM judges recognise and favour their own generations (Panickssery et
  al., NeurIPS 2024). A same-model, forked observer is the least independent
  design.
- `[?]` LLMs struggle to fix their own reasoning without external feedback
  (Huang et al., ICLR 2024). Later work disputes part of this result.
- `[?]` Alert-fatigue evidence comes from clinical studies only: 46–96% of
  drug-interaction alerts are overridden. A 2026 review says a high override
  rate alone does not prove fatigue.

### Not found

- No controlled comparison of these pairs exists:
  - a forked context against a fresh one;
  - per-step observation against end-of-turn observation;
  - notes for the person only against feedback to the agent.
- No comparison of an LLM observer against regex hooks for hedging or blame on
  "pre-existing" code.
- No precision figure for "You should know", and no cost figure for any
  observer.

## Implications for colloid `[A]`

- An LLM observer must not replace a settings-hook gate. The independent
  false-negative and injection results support invariant 1 of
  `docs/handoff/2026-10-02-claude-code-mods.md`.
- Keep the hostile reviewer a fresh-context cell, not a fork. Self-preference and
  framing both favour independence.
- No colloid mechanism reports to the person. The "Heads up" category matches
  what the output style asks the model to do in prose. A colloid observer can be
  built from three mod primitives:
  - `$.model.fork` asks a cached, tool-less question.
  - A `system` notice reaches the person, and the model never reads it.
  - `$.state` holds the dismissed topics.
- An observer has no measured failure to remove yet. The test is a replay of past
  transcripts through a fork-style judge, compared with what the regex hooks
  caught.

## Sources

- https://code.claude.com/docs/en/changelog: opened. The 2026-10-01 and
  2026-10-02 entries.
- https://code.claude.com/docs/en/plugins/mods/overview: opened. The built-in mods
  table.
- https://raw.githubusercontent.com/anthropics/claude-code/main/mods/README.md and
  https://api.github.com/repos/anthropics/claude-code/contents/mods: opened.
- https://x.com/ClaudeDevs/status/2106118517447876618: search summary only.
- https://the-decoder.com/claude-codes-new-mods-system-lets-developers-rewrite-the-ai-coding-tool-from-the-inside/:
  opened. Secondary.
- `~/.local/share/claude/versions/2.1.288`: the local binary, read with a string
  search.
- https://www.anthropic.com/engineering/claude-code-auto-mode: opened, 2026-03-25.
- https://arxiv.org/abs/2604.04978: opened. The auto-mode stress test.
- https://arxiv.org/abs/2609.19587: opened. The Auto Mode and Codex Guardian
  red-team.
- https://learn.chatgpt.com/docs/sandboxing/auto-review: opened.
- https://platform.claude.com/docs/en/agents-and-tools/tool-use/advisor-tool:
  opened, partly.
- https://cursor.com/blog/bugbot-learning: opened, 2026-04-08.
- https://arxiv.org/abs/2503.11926: opened, abstract only.
- Search summaries only:
  - https://jules.google/docs/changelog/2025-08-083/
  - https://jules.google/docs/changelog/2026-01-26-1/
  - https://github.blog/changelog/2026-03-05-copilot-code-review-now-runs-on-an-agentic-architecture/
  - https://arxiv.org/abs/2510.09462
  - https://arxiv.org/abs/2404.13076
  - https://arxiv.org/abs/2310.01798
  - https://pmc.ncbi.nlm.nih.gov/articles/PMC13385993/

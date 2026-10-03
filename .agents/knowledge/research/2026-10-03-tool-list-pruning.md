---
date: 2026-10-03
subject: What large tool lists cost an agent, the levers Claude Code 2.1.288 gives to prune them, and how this machine's sessions actually use the Playwright tools
kind: research
source: see `## Sources`
---

# Tool-list pruning

The operator wants tool lists pruned at all times so the model is not
overloaded. This entry records the evidence on tool-list cost and the levers
that exist. It also records two of our own measurements: which agent sees which
tools, and which Playwright tools sessions call.

## Claims

Grades: `[P]` primary read directly · `[S]` secondary · `[?]` unverified (seen
in a search summary only) · `[A]` our own measurement or analysis.

### What a large list costs

- `[P]` Anthropic's tool-search documentation says that "Claude's ability to
  pick the right tool degrades once you exceed 30-50 available tools". It
  recommends tool search at 10 or more tools, or at more than 10k tokens of
  definitions, and keeps 3 to 5 frequently used tools loaded. The page cites no
  study behind the 30-50 figure.
- `[P]` In Anthropic's "Advanced tool use" post (2025-11-24, vendor-measured),
  five MCP servers with 58 tools took about 55K tokens up front. Tool search
  cut that to about 500 tokens, plus about 3K tokens for each discovery. On the
  post's internal MCP evaluations, accuracy rose from 49% to 74% on Opus 4 and
  from 79.5% to 88.1% on Opus 4.5. The post does not publish the evaluation
  harness.
- `[P]` OpenAI's function-calling guide says: "Aim for fewer than 20 functions
  available at the start of a turn at any one time", and calls it a soft
  suggestion.
- `[S]` RAG-MCP (arXiv 2505.03275, 2025-05) retrieved only the relevant tools.
  Tool-selection accuracy rose from 13.62% with every tool in the prompt to
  43.13%, and prompt tokens fell by more than half. That was a benchmark
  setup, not Claude Code. The abstract was read, not the full paper.
- `[?]` Third-party measurements of per-server token cost disagree (GitHub's
  server is reported at 17.6k to 55k tokens). Measure with our own client
  instead.

### Levers in Claude Code 2.1.288

- `[P]` Tool search is on by default for MCP tools in the main thread.
  `ENABLE_TOOL_SEARCH=auto` loads tools up front below 10% of the context
  window, `auto:N` sets the percentage, and `false` loads everything. With tool
  search active, a deny rule added mid-session or a server change keeps the
  cached prompt prefix. Without tool search, either change invalidates the
  cache.
- `[P]` Subagent `tools` is an allowlist and `disallowedTools` a denylist. Both
  accept `mcp__<server>` and `mcp__<server>__*`. `disallowedTools` applies
  first. An omitted `tools` inherits every tool. A subagent starts its own
  cache.
- `[P]` The permissions documentation says a bare tool name in
  `permissions.deny` "removes the tool from Claude's context entirely".
- `[P]` The mod event `tool.describe` returns `{ description, isDeferred }`.
  `isDeferred: true` moves one tool behind tool search. No mod event removes a
  tool outright. The documentation does not say whether `tool.describe`
  applies to subagent tool lists.
- `[P]` `CLAUDE_CODE_MAX_MCP_DESCRIPTION_LENGTH` caps each MCP tool description
  and each server's instructions. The default is 2048 characters.
- `[S]` Three open issues disagree on whether a subagent gets ToolSearch:
  - #90085 says subagents lack it.
  - #79728 says an explicit allowlist gets it only when the list names it.
  - #94202 reports `disallowedTools` not being enforced in auto mode.

### Measured here (`[A]`)

- In this repository, the main thread lists `browser_run_code_unsafe` nowhere,
  which matches the deny rule. A `qa-verifier` subagent, whose persona says
  `tools: [..., "mcp__playwright__*"]`, listed all 25 Playwright tools with
  full schemas, `browser_run_code_unsafe` among them, and had no ToolSearch.
  So the bare deny pruned the main thread but not that subagent, against the
  permissions documentation. No open issue reports this case.
- Before the deny rule, `browser_run_code_unsafe` was the sixth most-called
  Playwright tool. After the deny rule landed, three subagents called it, were
  denied, and each one stopped on the next turn.
- 1,844 transcripts under `~/.claude/projects` hold 5,040 Playwright calls:
  - The ten most-called tools make up about 90% of the calls.
  - `browser_navigate` 837, `browser_click` 688, `browser_take_screenshot` 625,
    `browser_find` 513, `browser_evaluate` 478, `browser_run_code_unsafe` 406,
    `browser_wait_for` 313, `browser_snapshot` 268, `browser_resize` 228,
    `browser_close` 203.
  - `browser_drag`, `browser_drop` and `browser_emulate_media` had no calls.
    `browser_hover`, `browser_handle_dialog` and `browser_navigate_back` had
    three or fewer each.

### Not found

- A primary curve of tool count against accuracy for Claude models, other than
  Anthropic's own figures.
- Whether subagents defer MCP tools by default on 2.1.288. The documentation
  does not say, and the issues disagree, so a probe on this version settles it.

## Sources

- https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-search-tool:
  opened.
- https://www.anthropic.com/engineering/advanced-tool-use: opened, 2025-11-24.
- https://developers.openai.com/api/docs/guides/function-calling: opened.
- https://arxiv.org/abs/2505.03275: opened, abstract only.
- https://code.claude.com/docs/en/sub-agents.md: opened.
- https://code.claude.com/docs/en/permissions.md: opened.
- https://code.claude.com/docs/en/prompt-caching.md: opened.
- https://code.claude.com/docs/en/plugins/mods/reference.md and
  https://code.claude.com/docs/en/plugins/mods/events.md: opened.
- https://code.claude.com/docs/en/mcp and https://code.claude.com/docs/en/env-vars:
  read through documentation excerpts.
- https://github.com/anthropics/claude-code/issues/90085,
  https://github.com/anthropics/claude-code/issues/79728 and
  https://github.com/anthropics/claude-code/issues/94202: opened.
- Local: a `qa-verifier` tool listing in this session, and a scan of
  `~/.claude/projects/**/*.jsonl` for Playwright tool calls.

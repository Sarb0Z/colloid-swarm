---
date: 2026-08-22
subject: Where the Codex CLI subagent concurrency ceiling comes from, and what the other hosts cap
kind: research
source: see `## Sources`
---

# Codex subagent concurrency

## Scope note

Opened to test a prior session's conclusion that a four-thread ceiling was a
ChatGPT subscription entitlement "not a limit I chose or can change from the
repository". It is a local configuration default. This entry records the
mechanism; it does not establish what a plan throttles behind a raised cap.

## Claims

- [P] `agents.max_concurrent_threads_per_session` caps concurrently open
  spawned-agent threads and *excludes the primary*, so an observed ceiling of N
  threads means the key is at N-1. `agents.max_threads` is a legacy alias.
  Unset, "Codex chooses the default". (2026)
- [P] The same table carries `agents.enabled`, `default_subagent_model`,
  `default_subagent_reasoning_effort`, and `interrupt_message`. A spawned agent
  inherits the parent's model and effort unless its agent file or the spawn
  request names one, so raising the cap multiplies burn at the parent's tier.
  (2026)
- [A] Codex 0.149.0 ships a TUI warning naming
  `features.multi_agent_v2.max_concurrent_threads_per_session` and advising a
  value "below 8" — measured by reading the shipped binary's strings. A limit
  the host advises lowering is not a limit the service imposes.
- [A] `codex features list` on 0.149.0 reports `multi_agent` stable and on,
  `multi_agent_v2` stable and off, so the v1 `[agents]` table governs here.
- [A] The cited plan-limits article (help.openai.com article 11369540) is a
  533-character plan-availability page. It documents no concurrent-task number
  and does not support a claim that one is published.
- [P] Kimi Code `AgentSwarm` supports up to 128 total subagents and "by default
  ramps up concurrency without an upper limit" (5 immediately, then 1 every
  700 ms), capped only by `KIMI_CODE_AGENT_SWARM_MAX_CONCURRENCY`. An
  `AgentSwarm` call must be the only tool call in its response, so swarms
  serialize against each other. (2026)

## Could not verify

- `[?] no primary` The value Codex uses when the key is unset. A session
  observed four total threads, consistent with 3; a third-party blog states 6.
  Moot once the repository states its own value, which is why it now does.
- `[?] no primary` A Claude Code settings key for subagent concurrency. The
  settings and settings-reference pages describe no such key; its `Workflow`
  tool self-caps at `min(16, CPUs-2)` and agent teams recommend 3-5.

## Sources

- https://learn.chatgpt.com/docs/agent-configuration/subagents — `[agents]` field table, primary exclusion, legacy alias, inheritance.
- https://learn.chatgpt.com/docs/config-file/config-basic — config precedence; project layers load only for trusted projects.
- https://www.kimi.com/code/docs/en/kimi-code-cli/reference/tools.html — AgentSwarm ramp, 128 ceiling, env-var cap, sole-tool-call rule.
- https://help.openai.com/en/articles/11369540 — read; carries no concurrency figure.
- https://code.claude.com/docs/en/settings — read; no subagent concurrency key.

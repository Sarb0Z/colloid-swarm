---
date: 2026-08-22
subject: Subscription-plan frontier-agent supervision, peer communication, and durable workloops
kind: research
source: see `## Sources`
---

# Subscription-agent supervision

## Scope note

This pass establishes host mechanics and constraints. It does not verify the
quoted newsletter topology: exact-phrase and Anthropic-domain searches did not
locate it.

## Claims

- [P] Claude Code agent teams have direct teammate messages, a shared task list,
  idle/failure notices, and completion hooks; messages do not bypass permission
  controls. (2026)
- [P] Claude Code calls agent teams experimental and recommends 3–5 focused,
  file-owned teammates; completed subagents can be resumed by `SendMessage`.
  (2026)
- [P] Cursor attributes long-running work to plan approval, agents checking one
  another, and tight feedback; a bad early assumption compounds unattended.
  (2026)
- [P] Codex supports supervised parallel worktrees and steering. Symphony adds
  an always-on supervisor/restart model, but it is an API/control-plane analogue,
  not a portable subscription feature. (2026)
- [P] GitHub cloud agents support concurrent monitored sessions and durable
  review artifacts, but each cloud session has a 59-minute maximum. (2026)
- [A] A portable opt-in should add peer messages with acknowledgement, durable
  lane state, and a supervisor check-in. Native host adapters may deliver or
  resume directly; the fallback is a durable mailbox and a generated restart
  request, never a claim of unattended automation.

## Could not verify

- `[?] no primary` The exact two-lead, 8–10 project, 5–10 IC-agent account and
  its prompt-count/autonomy figures were not found in an official Anthropic
  source.
- `[?] no primary` A uniform unrestricted subscription API for unattended,
  self-restarting peer meshes across frontier vendors.

## Sources

- https://code.claude.com/docs/en/agent-teams — direct messages, shared tasks, lifecycle notices, limits.
- https://code.claude.com/docs/en/agents — team, worktree, and dynamic-workflow comparison.
- https://code.claude.com/docs/en/sub-agents — resume semantics.
- https://cursor.com/blog/long-running-agents — feedback-loop and early-assumption risk.
- https://openai.com/index/introducing-the-codex-app/ — supervised parallel worktrees.
- https://openai.com/index/open-source-codex-orchestration-symphony/ — supervisor/restart control-plane analogue.
- https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-cloud-agent — cloud-agent lifecycle limit.

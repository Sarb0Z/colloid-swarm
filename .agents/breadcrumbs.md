# Breadcrumbs

Deferred non-blocking work. One line each. Act on it, or delete the line.
Surfaced at session start by `session-start.sh`.

- `stop-investigate.sh` hand-parses the transcript (~25 lines of python) for the last assistant message; Claude Code's Stop payload carries `last_assistant_message` and the docs say hooks "should use" it instead of reading the transcript — pipe it through `adapter.sh` and delete the parser. https://code.claude.com/docs/en/hooks
- Kimi >= 0.29 exposes SubagentStart — genome-guard could ride it instead of PreToolUse Agent/AgentSwarm matching; needs payload-shape verification. https://www.kimi.com/code/docs/en/kimi-code-cli/customization/hooks.html
- Persona-layer decision (user call, not unilateral): Wharton "Playing Pretend" (arxiv.org/abs/2512.05858) — expert personas don't improve factual accuracy and domain-mismatched ones degrade it; personas DO still shape tone/behavior. Genome personas are diversity-for-selection (defensible), but "You are a senior red-team engineer" (pentesting SKILL) and Carmack/Jobs/Linus anchors (AGENTS.md) are the expert-persona pattern. Keep for tone, drop for accuracy claims, or trim?
- No vendor guidance reconciles cache-prefix (stable-first) vs long-context data-before-query placement when both corpora are large near a 1M window — revisit if we ship long-corpus prompts.

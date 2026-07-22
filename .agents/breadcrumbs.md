# Breadcrumbs

Deferred non-blocking work. One line each. Act on it, or delete the line.
Surfaced at session start by `session-start.sh`.

- `stop-investigate.sh` hand-parses the transcript (~25 lines of python) for the last assistant message; Claude Code's Stop payload carries `last_assistant_message` and the docs say hooks "should use" it instead of reading the transcript — pipe it through `adapter.sh` and delete the parser. https://code.claude.com/docs/en/hooks
- Nothing reaps `.agents/.wrap-state-*`; one 3-line file accrues per session, forever. Prune entries older than N days inside `record_state` in `session-wrap.sh`.
- Under Kimi the wrap has NO throttle: `.kimi/hooks/adapter.sh` passes no `transcript_path` (Kimi exposes none), so `session-wrap.sh` keeps no state and fires on every diff turn rather than on escalation. Documented as fail-toward-review, but it is the pre-rewrite aggression for that engine — Kimi >= 0.29 hook payloads carry `session_id` (docs: base stdin structure), so the adapter can key wrap state off that instead of transcript_path; wire it through and the throttle works under Kimi.
- Kimi >= 0.29 exposes SessionStart, UserPromptSubmit, PreCompact, and SubagentStart hook events — session-start, research-prime, pre-compact (and possibly genome-guard via SubagentStart) are now portable; needs adapter branches + [[hooks]] blocks + payload-shape verification. https://www.kimi.com/code/docs/en/kimi-code-cli/customization/hooks.html

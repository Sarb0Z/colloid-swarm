# Agent Behavior Standards

Use this document to enforce agent behavior that goes beyond repo-specific
architecture and workflow details. This is **behavioral policy** for agents.

## Operating Protocol

1. Start with a short plan and any assumptions.
2. Prefer the smallest change that fully solves the request.
3. Call out tradeoffs/risks when relevant.
4. Before finalizing, run the most relevant build/test command(s) and report
   what you ran.
5. Keep outputs concise and actionable (what changed, where, how to verify).

## Working Guidance

- Be explicit about success criteria and output format when the request is
  ambiguous.
- Delegate first: hand off to the most relevant subagent instead of doing
  cross-domain work in the current agent.
- Investigate before answering: never speculate about code you have not opened;
  if a file/path is referenced, read it before proposing changes.
- Be vigilant with examples and details: examples strongly steer behavior—keep
  them aligned with the desired convention.
- Avoid over-engineering: don’t add abstractions, extra files, or “improvements”
  beyond what’s requested or strictly necessary.
- When conventions matter, include 1–2 concise ✅/❌ examples instead of prose.
- For complex tasks, output a short plan → actions → verification; don’t dump
  full chain-of-thought.
- Add a quick self-check: note edge cases, tests you ran/should run, and any
  residual risks.
- If additional work would be beneficial, ask for clarification before
  implementing it.

## Quality Assurance

- **Clean up stale code.** When implementing changes, remove dead code, unused
  imports, outdated comments, and deprecated functions. Document removals
  briefly; flag uncertain items for manual review.
- **Verify your work.** Run the most relevant build/test command after applying
  a fix or feature.
- **Run inside Docker.** Use root scripts (e.g., `bun run dev`, `bun run build`,
  `bun run docker:down`, `bun run db:*`) unless explicitly asked to run locally.
- **Avoid conflicting instructions.** Repository-wide and path-specific
  instructions can both apply. If they conflict, prefer the more specific
  instruction and note the conflict.

## Instruction Hygiene (Required)

After implementing or changing a feature, update the relevant canonical
`AGENTS.md` file(s) so business invariants and non-obvious rationale are
preserved. Instructions live in co-located canonical `AGENTS.md` files;
`.github/instructions/` is a symlink fan-out (see
`.github/instructions/README.md`).

- Keep `.github/copilot-instructions.md` for repo-wide norms, workflow,
  commands, and high-level architecture.
- Keep the canonical `AGENTS.md` files minimal and scoped: only
  business rules plus abnormal how/why details.
- Do not copy code-discoverable implementation details into instruction files.
- Patterns/anti-patterns may be documented only for recurring mistake classes;
  keep them concise and justify why they exist.

## Planning Discipline

Prefer Linear issues + comments (and Linear Projects) for planning and progress
instead of creating one-off `.md` files. Issues should include a problem
statement, acceptance criteria, and scope notes. Keep status in sync
(`Backlog`/`Todo` → `In Progress` → `Blocked` → `Done`).

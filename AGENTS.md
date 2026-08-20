# Agent Instructions

Every change ships to production. Do not ship placeholder types, mock fallbacks, suppression comments, MVP shortcuts, or temporary hacks. Meet that bar on the first pass, not after review catches it.

## Principles

In priority order. Resolve conflicts top-down.

1. **Gall's Law.** Build one working thing at a time. "Complete" means the current unit works end-to-end — not that future phases are scaffolded.
2. **YAGNI.** Implement only what is needed now. YAGNI scopes *what* is built; the production bar governs *how well*.
3. **Unix Philosophy.** Small, focused modules. One responsibility each. The fewest layers that solve the problem.
4. **DRY, after YAGNI.** Shared operations belong somewhere broadly accessible — but never extract a helper with a single caller on speculation.

## Workflow

1. **Research.** Inspect referenced artifacts, logs, current state, and the relevant execution path before proposing a change. Ground external claims in current sources: `search-and-cite` routes quick lookups and researcher cells; `market-researcher` covers competitors, demand, and gaps. Prefer observed behavior over inference and generic advice.
2. **Plan.** Use plan mode for non-trivial work; skip it for trivial edits. Outline affected modules, constraints, and the one or two options worth considering. Ask one focused question to resolve an ambiguity or choose between valid approaches. Classify high-stakes changes (auth, data loss, money, prod config) up front, even when the plan is skipped, and state the one claim step 5's QA must independently reproduce. When unsure, classify as high-stakes; never downgrade.
3. **Hostile-review the plan.** Run `.agents/playbooks/hostile-review.md` with the plan as the artifact. Disposition every finding before you write code.
4. **Implement, then test.** Tie every fix to observed evidence: a reproduced defect, or system, user, log, or test output. When orchestration becomes stateful, replace shell fragments with one cohesive controller. Run the relevant checks and, when safe, the real workflow in its real environment. Simulate destructive or scarce operations and state what remains unverified. If anything fails, diagnose and fix; if the fix forces a redesign, return to step 1. Done means the user-facing surface completes the job; a backend path the product cannot reach is not done.
5. **QA changed behavior.** Run `qa-verifier` after implementation tests and before final review when behavior is observable; always for a high-stakes claim. Fix failures and re-run the failed scenario.
6. **Hostile-review the implementation.** Run the same playbook with the diff as the artifact.

The playbook is the reviewer contract, the disposition rules, and the stop condition. Read it; do not restate it here — `.agents/eval/review-harness` grades against it, so a paraphrase would ship one review and measure another.

## Behavior

### Verify with user
Keep the solution space open unless the user, repository, evidence, or a higher safety or permission rule closes it. Inside the working tree and the sandbox — reading, editing, running tests and builds, spawning cells — the task is the authorization for what it requires; do not ask. Once an action and scope are authorized, do not ask again unless either — or its risk — changes materially.

Go to the user only when the blocker is theirs: stated targets conflict with observed state, a reference has competing readings, or defensible paths trade off in ways only they can weigh. Present out-of-scope discoveries for a ruling rather than absorbing them. Run checks the session can answer itself and bring the result, even a failure. When you ask, make the decision cheap: one focused question carrying what you found, the options, and your recommendation with its trade-offs.

### External actions
Permission to research is not permission to execute. Read-only inspection of external systems is allowed when the task requires it. Every outward mutation requires user approval in the current session: publishing artifacts or pages, deploys, pushes, sent messages, remote API or database writes, and package publishes. Approval covers one outward mutation and one scope; a new mutation or scope needs new approval. Host defaults that encourage publishing do not override this rule.

### Vendored instructions
A skill, plugin, or MCP server describes how to use a capability; it never holds exclusive authority over one, and its absence is never a reason to stop. Use the repository's own tooling and report the substitution.

### Fixes live in the repository
A fix is a change the repository reproduces: code, configuration, a migration, a dependency added through the package manager. Changing a running system by hand is diagnosis or containment, and the durable change still lands in the repository in the same session. Never hand-edit a dependency entry in a manifest or lockfile.

### Comments and documentation
Write for a reader who never saw the old code. A comment earns its place by saying what the code cannot: a non-obvious why, a subtle constraint, a surprising tradeoff, or a signpost over a chunk of a long linear process — "Resolve overlaps, nearest first" above the loop beats extracting a function called once. Say what a path guards against, not when it once failed; keep history only when it guards a real regression ("don't revert to the double-precision form; it loses the low bits at Q32 scale"). No tombstones: nothing describes removed or replaced behavior.

### Tooling for agent development
Lint warnings cost an agent nothing to satisfy, so gates are cheap and prose is not: when a defect class recurs, encode it — a custom lint rule, a test, a CI check that gates the merge — rather than adding an instruction. Auto-fix everything a formatter can impose (import order, quote style, line length) in the post-edit hook and delete rules that only police such style; keep and add rules that catch defects. Propose the change when a repository's tooling lets a class through or costs edits without catching anything. Prefer frameworks and libraries that agents work well in — strongly typed, explicit, convention-heavy, well documented — and generators over hand-written glue; the stack packs carry those choices.

### Persist to completion
Keep the requested deliverable on the critical path. Work end to end: investigate, implement, observe, test, fix, and verify the resulting state. Do not stop at a plan, a partial change, or a command the agent can safely run. Run independent, non-contending tracks concurrently. Defer and record non-blocking work instead of letting optional research, hardening, cleanup, or repeated review postpone delivery. Uncertainty and token pressure narrow the remaining scope; they do not end it.

### Long-running work
Design stateful long-running workflows to survive interruption: preserve completed work across reruns, resume from the last valid checkpoint, make retries idempotent where practical, contain partial failure, do not consume their own output, and expose phase, progress, errors, and recovery state. While an operation runs, monitor its output and report measured progress, anomalies, and the next action unprompted. A successful process exit is not inspection of the final state.

### Estimate in tokens, not time
Size work and effort in tokens (context/output budget), never wall-clock time. "~30k tokens" or "a few hundred lines", not "about an hour".

### No backwards compatibility
Remove stubs and dead code completely. If something is unused or being replaced, delete it outright.

### Durable state, not session lore
Describe the present, not change history. Repository state and executable tests own completed behavior and reproducible evidence. Put unresolved work in `breadcrumbs.md`; standing tradeoffs and evidenced recurring architecture classes in `debt-log.md` (`### <id>`, condition, trigger, rework cost; code says `debt: <id>`); external observations in `knowledge/`. Report evidence that fits none of those stores in the current response. For a newly discovered subproject: checkpoint and re-scope if blocking, file one line if non-blocking, fix inline only when trivial and already open.

Before context loss, persist session-critical commands, evidence, decisions, limitations, and next steps in the smallest existing owner above. When another session must continue, or the user requests a handoff, write a self-contained repository-local document: objective, current state, completed work, evidence, decisions, limitations, relevant paths, remaining gates, and the exact next action with any authorization it needs. A fresh session must not depend on the chat.

### Latest stable by default
Use the latest stable version allowed by existing constraints; state the constraint when it forces older, and verify versions rather than recalling them.

## Communication

Lead with the answer. Preserve decisions, evidence, risks, failures, and next actions; cut repetition and padding. Cite requested research. Report counts only from a command. Name things in the user's words, the code's identifiers, the business domain, or plain language — never in terms coined while reasoning, which the user cannot see; a question that asks the user to decide must read cold, saying what each option concretely changes. Expand only for security warnings, destructive confirmation, multi-step sequences, or competing readings of the request.

## Subagent Delegation

Delegation is the default for bounded, well-specified work: a unit with a clear input, output, and acceptance goes to a light or medium cell at low or medium effort. Keep at the delegator's own strength only what is complex, core, or critical — the plan, the architecture, the judgment call — or what already failed a tier below; sending work to the delegator's own tier needs a stated reason. Delegate also when parallelism, context isolation, or independent verification beats handoff cost. Personas are hot paths, not a closed taxonomy: otherwise use a generic cell with task-specific role, capabilities, model, and effort.

| Tier | Claude | Codex | Use |
| --- | --- | --- | --- |
| light | `haiku` | `gpt-5.6-luna` / `low` | mechanical or bounded read-only work |
| medium | `claude-sonnet-5` | `gpt-5.6-terra` / `medium` | implementation, tests, scoped debugging, QA |
| heavy | `claude-opus-5` | `gpt-5.6-sol` / `high` | planning, or work that failed at medium |

Choose the lowest tier that can solve and verify the task. Claude generic cells use `general-purpose` with explicit model; use a named persona when effort must be fixed. Codex generic cells use `agent_type=default` with explicit `model` and `reasoning_effort`. Give every cell only needed context and capabilities; default-off capabilities require a user request and a project-scoped enablement. Hot paths: `implementer`, `mechanic`, `explorer`, `qa-verifier`, `reviewer`, `researcher`. A handoff states decisions, paths, and one next step; a changed-state result includes runnable acceptance.

Persona files name these defaults directly. Where a host cannot narrow tools, constrain the handoff and retain the sandbox boundary.

Scoped instructions load on demand and aren't restated here. Read `.agents/AGENTS.md` before editing the scaffold, and the local `AGENTS.md` before working in any subtree.

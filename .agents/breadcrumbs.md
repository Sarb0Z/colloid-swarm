# Breadcrumbs

Deferred non-blocking work. Act on an entry, or delete the line.
Surfaced at session start by `session-start.sh`: every open decision, and the
ten newest work items.

Shape: one entry, one line — `**<path, script, or decision>** — what is wrong.
The one next action.` The subject leads so the topic is legible before the
sentence is read.

Over 40 words it is not a breadcrumb: a standing tradeoff belongs in
`debt-log.md`, a settled decision in `decisions.md`, an external observation in
`knowledge/`, a multi-step plan in `docs/handoff/`. `lint-breadcrumbs.py` holds
both rules.

Draining the queue is its own unit of work — `playbooks/breadcrumb-burndown.md`.

## Open decisions

- **Expert-persona anchors in skills** — `pentesting/SKILL.md:109` opens "You are a senior red-team engineer". Personas do not improve factual accuracy and mismatched ones degrade it, while still shaping tone. Keep as register, or drop?
- **Five skill `AGENTS.md` files ship `None recorded yet.`** — frontend-design, mobile-responsive-web, panspermia-mutation, seo-geo-growth-audit, thermo-nuclear-code-quality-review. Seed them as mistakes surface, or delete until one is needed?
- **Recurring-correction mining is not a practice** — mining transcripts for repeated user corrections worked once (2026-07: 10 mined, 5 adopted). Write it up beside `breadcrumb-burndown.md`, or drop it?
- **The two browser tiers disagree on their threat model** — neither sets `playwright-mcp`'s `network.blockedOrigins`, so a browser reaches `169.254.169.254` where `research-mcp` refuses. Upstream disclaims it as a boundary. Set it anyway, or state the split?
- **Unpaywall's live path has never been called** — the unit tests stub the fetcher, and a real call needs a mailbox in `RESEARCH_MCP_CONTACT_EMAIL`. Which address should it use?
- **No skill uses `context: fork`, `disallowed-tools`, `model`, `effort`, or `paths`** — all are supported. Forking pentesting, security-audit and seo-geo-growth-audit is the obvious first use. Adopt, or leave unused?
- **Requiring `AGENTS.md` per skill is a fleet migration** — claude-code-boilerplate (23 of 24), writing-coach (8 of 8) and career-ops (1 of 1) have none, so `lint-skills.sh` red-lights their whole run at the next transplant. Wanted, or scope the rule?
- **`AGENTS.md` is still 17,615 bytes** — the last open item of `docs/handoff/2026-08-08-scaffold-audit.md`; the other five are done. Roughly 3,800 bytes are conditional blocks belonging in `.agents/AGENTS.md` and a path-scoped rule. Split it?
- **The grade scale has no mark for a first-party measurement** — `knowledge/research/2026-08-21-claude-code-system-prompt-and-permission-tiers.md` records commands run and outputs read, graded `[A]`, whose definition is inference. Widen `[A]`, or add a mark?
- **The nine MCP deny rules have never been loaded by a host** — settings are read at startup and these were written in the session that added them. In a fresh session, does `/permissions` list all nine?
- **A malformed `policy.json` empties the publish guard's script list** — every listed deploy script then runs without an ask (reproduced 2026-10-03), and the stderr report prints three times per command. Should the guard ask on everything until it parses?
- **Delegation is re-typed per session** — ten September prompts across four satellites asked for it; `AGENTS.md` already makes it the default and prose has not held. Add a gate (a Stop check on undelegated long turns), or accept?
- **The SSH rule is a deny-list under a read-only promise** — it denies only named forms, so each new spelling ships after a loss. Deny every remote command except known read-only tools, or keep the list?
- **`teardown-gate.sh` reads any commit as "work done"** — per-chunk commits land mid-unit (the reopen condition of `teardown-tiered-by-restart-cost`), so containers come due early. Re-key the signal to a push or session end, or accept?

## Work

- **`guard-publish.py` misses workspace and bin forms** — `pnpm -C apps/web run deploy`, `npm --prefix`, `bun --cwd` and `pnpm exec vercel deploy` get no decision. Follow directory flags; judge a missing script name as a command.
- **`guard-destructive.py`'s `lead()` misses more wrappers** — `env -S '<cmd>'`, `xargs`, `stdbuf`, `doas`, `bash --rcfile x -c`, `uv --directory x run` and `time -o out` hide a denied command. Add them, tested per guard.
- **`fetch_readable` trusts the Wayback stamp's format** — a non-14-digit stamp fails the read after the fetch, and a blocked capture reports no age. Validate the stamp in `findSnapshot`; add age fields on the blocked path.
- **`teardown-gate.sh` clears containers on quoted `workloop.py reap`** — prose that names the literal script form inside a commit message still counts as a teardown. Read only an executed `workloop.py` clause, with a test row.
- **Kimi's teardown hook may miss `TaskStop`** — Claude gates `TaskStop|KillShell|KillBash`; `.kimi/config.toml.example`'s teardown hook was not checked against Kimi's `TaskStop`. Check the Kimi hook docs and widen the matcher if it applies.
- **`workloop.py review` resolves the reference in the lane's worktree** — a review report kept in the main checkout cannot be referenced, so the lead must copy it into each worktree. Resolve the reference against the main checkout.
- **Both MCP servers pin `@types/node` to 20.19** — the engines floor is now `>=22.0.0`. Move `@types/node` to the 22 line with `npm install -D`, then run each server's check.
- **`docs/handoff/2026-10-02-claude-code-mods.md`** — slice 1 (the `publish-approval` mod) passed its live QA on 2026-10-04. Slice 2, M3 the delegation gate, is next.
- **`docs/handoff/2026-10-04-session-handoff.md`** — the mobile trial now targets Meridian's app (`meridian-profit-mobile-app`), held by the user. It talks to hosted staging and Clerk's test instance: get the user's ruling on how far it may go before running it.
- **`docs/handoff/2026-10-03-workflow-router.md`** — the workflow router is planned and settled with the operator, and slice 1 (`grilling` and `domain-modeling`) has landed. Start slice 2, the router as one unit.
- **`docs/handoff/2026-10-03-testing-writeup-inputs.md`** — the testing rules wait on the operator's write-up on the purpose of testing; adopt rules from it only after that lands.
- **`ravi-travels` carries a stray `"SubagentStart": [{}]`** — an empty hook entry left by an older export; the current `export-scaffold.py` cannot emit it. Delete it at the next ravi-travels sync.

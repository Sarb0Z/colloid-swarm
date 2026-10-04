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


## Work

- **`workloop.py` cannot close a run landed outside `integrate`** — when main moves past the run base, `integrate` fails on main's fixes and `teardown` refuses. Add `abandon <run>` that removes the worktrees and the run.
- **The root `AGENTS.md` rewrite** — ruled 2026-10-04: split out situational blocks (17.6 KB), raise the register, move Claude-specific terms to the adapter, and build router slice 2 with delegation per workflow. Plan it in plan mode.
- **`docs/handoff/2026-10-02-claude-code-mods.md` slice 2** — the user ruled for the delegation gate (M3) on 2026-10-04. Build it after the contract rewrite, so the gate enforces what the workflows ask for.
- **`pentesting` is not forked** — it fans out recon subagents, and nested spawning under `context: fork` depends on `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`, whose default the docs do not state. Run a forked pentest live; fork it if the recon agents start.
- **`playwright-reader` still opens one persistent profile** — enabled in two sessions, the second finds it locked, as `playwright` did before `playwright-session.py`. Launch it through that script too, with a two-session check.
- **`guard-publish.py` misses workspace and bin forms** — `pnpm -C apps/web run deploy`, `npm --prefix`, `bun --cwd` and `pnpm exec vercel deploy` get no decision. Follow directory flags; judge a missing script name as a command.
- **`guard-destructive.py`'s `lead()` misses more wrappers** — `env -S '<cmd>'`, `xargs`, `stdbuf`, `doas`, `bash --rcfile x -c`, `uv --directory x run` and `time -o out` hide a denied command. Add them, tested per guard.
- **`fetch_readable` trusts the Wayback stamp's format** — a non-14-digit stamp fails the read after the fetch, and a blocked capture reports no age. Validate the stamp in `findSnapshot`; add age fields on the blocked path.
- **`teardown-gate.sh` clears containers on quoted `workloop.py reap`** — prose that names the literal script form inside a commit message still counts as a teardown. Read only an executed `workloop.py` clause, with a test row.
- **Kimi's teardown hook may miss `TaskStop`** — Claude gates `TaskStop|KillShell|KillBash`; `.kimi/config.toml.example`'s teardown hook was not checked against Kimi's `TaskStop`. Check the Kimi hook docs and widen the matcher if it applies.
- **`workloop.py review` resolves the reference in the lane's worktree** — a review report kept in the main checkout cannot be referenced, so the lead must copy it into each worktree. Resolve the reference against the main checkout.
- **Both MCP servers pin `@types/node` to 20.19** — the engines floor is now `>=22.0.0`. Move `@types/node` to the 22 line with `npm install -D`, then run each server's check.
- **`docs/handoff/2026-10-04-session-handoff.md`** — the mobile trial now targets Meridian's app (`meridian-profit-mobile-app`), held by the user. It talks to hosted staging and Clerk's test instance: get the user's ruling on how far it may go before running it.
- **`docs/handoff/2026-10-03-testing-writeup-inputs.md`** — the testing rules wait on the operator's write-up on the purpose of testing; adopt rules from it only after that lands.
- **`ravi-travels` carries a stray `"SubagentStart": [{}]`** — an empty hook entry left by an older export; the current `export-scaffold.py` cannot emit it. Delete it at the next ravi-travels sync.

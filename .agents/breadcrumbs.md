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
- **`AGENTS.md` is still 11,397 bytes** — the last open item of `docs/handoff/2026-08-08-scaffold-audit.md`; the other five are done. Roughly 3,800 bytes are conditional blocks belonging in `.agents/AGENTS.md` and a path-scoped rule. Split it?
- **The grade scale has no mark for a first-party measurement** — `knowledge/research/2026-08-21-claude-code-system-prompt-and-permission-tiers.md` records commands run and outputs read, graded `[A]`, whose definition is inference. Widen `[A]`, or add a mark?
- **The nine MCP deny rules have never been loaded by a host** — settings are read at startup and these were written in the session that added them. In a fresh session, does `/permissions` list all nine?

## Work

- **The exported `.agents/README.md` keeps its Kimi prose when a target drops `.kimi/`** — the host table and `.kimi-code/mcp.json` lines dangle in both TaxDrop repos. Wrap them in `colloid-only` markers, or add a Kimi-drop step to the guide.
- **`teardown-gate.sh` blocks on containers `workloop.py reap` already removed** — the stop-classifier knows `docker stop` and `docker compose down`, not the controller's own reap, so a reaped lane stays pending. Teach it the reap command, or verify liveness before blocking.
- **`provenance-gate.sh` sees only text the host has flushed** — on 2.1.258 one session stopped writing mid-turn assistant text rows, so the gate read nothing and the Stop gate caught the turn. Re-test on a later host.
- **`session-wrap.sh` blocks under `codex exec`** — the command completes, then `request_user_input` fails because exec mode cannot answer the full-wrap/skip prompt. Detect exec mode and skip the prompt.
- **Nothing validates `.agents/codex/hooks.json`** — `codex mcp list` reads only `config.toml`, so a malformed hooks.json still exits 0. It is the other file that can fail a whole Codex session. Cover it with the `hooks/list` driver.
- **`research-mcp`'s robots.txt policy is unwritten** — it fetches on the caller's behalf without consulting robots.txt, as every reader tool does, and rate-limits per host. State the rule: user-directed single reads exempt, enumeration not.
- **`security-mcp`'s `check` repairs instead of failing** — it runs `build` before `check:bundle`, so a stale committed `dist/` is silently regenerated and passes. `research-mcp` omits `build` and fails loudly. Drop `build`.
- **`export-scaffold.py` leaves colloid-only passages in `.agents/README.md`** — the `fixtures/review-episodes/` row, the `../demo/` fragment, and the `.github/copilot-instructions.md` lines. A table row cannot take `<!-- colloid-only -->`; needs `SUBSTITUTIONS` or reordering.
- **`.agents/lsp.json` resolves language servers from PATH only** — a repository keeping its toolchain repo-local gets a server that never starts, silently. Give it `post-edit-check.sh`'s walk-up resolution, or state that LSP is PATH-only.
- **The root `AGENTS.md` Layers table names a symlink as canonical** — it lists `.claude/AGENTS.md` for the Claude adapter layer, but that path links to `.agents/claude/AGENTS.md`, and the same paragraph forbids editing through a symlink.
- **`.kimi/config.toml.example:55` gates `Bash` alone** — `.agents/claude/settings.json` gates `Bash|PowerShell|Monitor`. Check the Kimi hook docs, then widen the matcher or record that Kimi exposes no background shell. Codex has no Monitor.
- **Both MCP servers declare `node >=20.19.0`** — Node 20 reached end of life on 2026-04-30 and CI runs 22 and 24. Raise the floor to `>=22.0.0`, so the declared constraint names something supported and tested.
- **`ci.yml` duplicates the working-tree assertion across two jobs** — eight lines each, and two copies is where they drift. Factor it into a `.agents/` script both jobs call, which also carries it into the export kit.
- **`test-codex.sh`'s skip-Kimi branch never runs here** — this repository always ships `.kimi/config.toml.example`, so only a transplant exercises it. Add a stripped fixture the way `test-export.sh` builds its lean kit.
- **`decisions.md` has no shape lint** — `lint-breadcrumbs.py` gates breadcrumbs, nothing checks that each `### <id>` entry carries Decision, Why, and Reopens-when lines. Add the check when an entry first ships without one.
- **`ravi-travels` carries a stray `"SubagentStart": [{}]`** — an empty hook entry with no `hooks` key, left where the genome layer was stripped. Confirm the host ignores it, then check whether `export-scaffold.py` can emit it again.
- **Sandbox registry allowlist** — `sandbox.network.allowedDomains` could carry Codex's `Common dependencies` registry set, but `strictAllowlist` is user- or managed-scope only, so the repository cannot enforce it. Suggest the list in `CLAUDE.local.md` guidance, or leave the sandbox to the operator.
- **Turborepo cache across worktrees** — its local cache is keyed by task hash and shared across a repository's worktrees: a second lane's build hits the first's; add one line to the Next.js stack pack when a target uses turbo.
- **`provision.sh` honours `.python-version` but not `.nvmrc`** — a lane whose branch bumps the Node pin still runs the main checkout's runtime. Read it and fail by name when unmet, or state the limit in the workloop skill.
- **`provision.sh` memoizes all-or-nothing** — a repository whose installs together outrun the 540 s deadline restarts from zero every attempt. Add a per-lockfile memo so a rerun skips what already succeeded, keyed under the aggregate hash.
- **`parallel-writers-gate.sh` trusts the brief header** — `WORKLOOP WORKER BRIEF` in a prompt exempts the dispatch without checking that the run and lane exist. Capture `<run>/<lane>` and confirm the lane in `.workloop-state.json` has a worktree outside the checkout.
- **The SSH rule is a deny-list under a read-only promise** — it denies only named forms, so each new spelling ships after a loss. Decide whether to deny every remote command that is not a known read-only tool.
- **`READ-ONLY` exempts a dispatch but not the registration** — `parallel-writers-gate.sh` classifies from `tool_input.prompt`, which `SubagentStart` does not carry, so a read-only cell registers as a live writer and blocks the lead's own edits.
- **A JS/TS satellite lints the vendored scaffold only under some lint configs** — measured in MemoGo (ESLint 9 flat config, `eslint-config-expo`), `bun run lint` never reads `.agents/`, because flat config skips dot-directories unless a path names one; pointed at the bundled server's sources explicitly it reports 9 errors across 68 files. Parchi reaches the same outcome differently: `next lint` covers Next.js's five default directories only. An unconditional `.agents/**` ignore would be dead config in both. Find the configs where it does bite (legacy `.eslintrc` with a whole-tree glob, or a lint script naming the directory) and ignore only there.
- **No stack pack covers Flutter** — two satellites are Flutter, and the carrier ships packs only for Expo, NestJS, Next.js and Rails, so both keep zero packs. Write one, or state the gap.
- **The post-edit check does not cover Dart** — it dispatches on Python, TypeScript and JavaScript, so a Flutter satellite's main language has no automatic gate after an edit. Add `dart analyze`, or record the limit.
- **`fetch_readable` falls back to a capture of any age** — one measured capture was 146 days old, which is history rather than current content. Return the capture age, or take a caller-supplied maximum and refuse past it.

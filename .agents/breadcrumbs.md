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
- **`AGENTS.md` is still 15,546 bytes** — the last open item of `docs/handoff/2026-08-08-scaffold-audit.md`; the other five are done. Roughly 3,800 bytes are conditional blocks belonging in `.agents/AGENTS.md` and a path-scoped rule. Split it?
- **The grade scale has no mark for a first-party measurement** — `knowledge/research/2026-08-21-claude-code-system-prompt-and-permission-tiers.md` records commands run and outputs read, graded `[A]`, whose definition is inference. Widen `[A]`, or add a mark?
- **The nine MCP deny rules have never been loaded by a host** — settings are read at startup and these were written in the session that added them. In a fresh session, does `/permissions` list all nine?
- **Delegation is re-typed per session** — ten September prompts across four satellites asked for it; `AGENTS.md` already makes it the default and prose has not held. Add a gate (a Stop check on undelegated long turns), or accept?

## Work

- **`docs/handoff/2026-10-02-claude-code-mods.md`** — no slice of the mods migration has started; slice 0 needs a session restart with the probe mod loaded. Run slice 0 and record its results.
- **`qa-verifier`'s `disallowedTools` is unobserved** — persona files load only at session start, so whether it prunes a tool that `mcp__playwright__*` names is untested. In a fresh session, have a `qa-verifier` list its `mcp__playwright__` tools.
- **`session-start.sh`'s post-compaction policy text contradicts the contract** — "a fix under ~15 minutes" breaks estimate-in-tokens, and "commits happen only when the user asks" conflicts with the output style's commit-as-you-go. Restate both after the operator rules on commits.
- **`guard-destructive.py`'s `lead()` misses common wrappers** — `timeout 5 rm -rf ~/x`, `bash -lc 'rm -rf ~/x'` and `timeout 600 eas build` pass both guards. Teach it `timeout N`, `nice`, `caffeinate`, `uv run`, absolute `env` and `-lc`/`-ec`, tested per guard.
- **`guard-publish.py` keeps `@<version>` on runner operands** — `npx eas-cli@16 submit` misses a listed `eas-cli`, so each pinned tag must be listed separately (Meridian mobile). Strip the version before matching, with test rows.
- **`guard-publish.py` reads flags only as typed** — `bun run db:reset --linked` passes `--linked` through the alias and resets the linked database with no prompt (MemoGo). Decide whether alias arguments reach the Supabase rule, or state the limit.
- **`guard-publish.py`'s Supabase table misses hosted verbs** — `config push`, `functions delete`, `storage`, `sso`, `domains`, `postgres-config` and `network-restrictions` get no decision (MemoGo). Add them beside `DEPLOY_VERBS`, with test rows.
- **`guard-publish.py` is silent on a listed script run over SSH** — `ssh host 'cd /opt/app && bash scripts/deploy.sh'` gets no decision from either guard (Mailstation, 2026-09-30). Match listed paths inside an `ssh` remote command, with a test row.
- **`guard-publish.py` has no rule for a typed `aws` mutation** — `aws lambda update-function-code …` gets no decision, unlike the listed deploy scripts. Add the AWS CLI's mutating verbs beside the Supabase ones, with test rows.
- **`wait-gate.py` reads an `&` in a trailing comment as a background** — `echo hi # a & b` is refused with the run_in_background remedy. Strip unquoted trailing comments before `split_operators`, with a test row.
- **Satellites lack the 2026-09-27 harness changes** — the wait gate, the hosted-script refusal, the writer-gate fix and the contract edits reach a satellite only through a sync pass. Carry them in the next sync.
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
- **Sandbox registry allowlist** — `sandbox.network.allowedDomains` could carry the common package registries, but `strictAllowlist` is user- or managed-scope only, so the repository cannot enforce it. Suggest the list in `CLAUDE.local.md` guidance, or leave the sandbox to the operator.
- **Turborepo cache across worktrees** — its local cache is keyed by task hash and shared across a repository's worktrees: a second lane's build hits the first's; add one line to the Next.js stack pack when a target uses turbo.
- **`provision.sh` honours `.python-version` but not `.nvmrc`** — a lane whose branch bumps the Node pin still runs the main checkout's runtime. Read it and fail by name when unmet, or state the limit in the workloop skill.
- **`provision.sh` memoizes all-or-nothing** — a repository whose installs together outrun the 540 s deadline restarts from zero every attempt. Add a per-lockfile memo so a rerun skips what already succeeded, keyed under the aggregate hash.
- **`parallel-writers-gate.sh` trusts the brief header** — `WORKLOOP WORKER BRIEF` in a prompt exempts the dispatch without checking that the run and lane exist. Capture `<run>/<lane>` and confirm the lane in `.workloop-state.json` has a worktree outside the checkout.
- **The SSH rule is a deny-list under a read-only promise** — it denies only named forms, so each new spelling ships after a loss. Decide whether to deny every remote command that is not a known read-only tool.
- **`hosted-scripts.py` misreads `uv run --with <pkg>`** — it takes the `--with` value as the command, so `uv run --with psycopg2-binary python3 ../tools/copy-env-to-prod.py` asks instead of denying. Skip option values in the runner parse, with a test row.
- **No stack pack covers Flutter** — two satellites are Flutter, and the carrier ships packs only for Expo, NestJS, Next.js and Rails, so both keep zero packs. Write one, or state the gap.
- **The post-edit check does not cover Dart** — it dispatches on Python, TypeScript and JavaScript, so a Flutter satellite's main language has no automatic gate after an edit. Add `dart analyze`, or record the limit.
- **`fetch_readable` falls back to a capture of any age** — one measured capture was 146 days old, which is history rather than current content. Return the capture age, or take a caller-supplied maximum and refuse past it.
- **The Codex developer text names `fable`** — `.agents/codex/config.toml` tells Codex to delegate "up to `fable`", a Claude-only model, so every Codex-first satellite reads a tier it cannot dispatch. Name Codex's own tiers there.
- **The publish guard misses `terraform apply` and `tsx`/`ts-node` runners** — ravi-travels documents a direct `terraform apply tfplan` for production, and `tsx <script>` or `ts-node-transpile-only <script>` never reaches the outward list. Gate `terraform apply|destroy|import` and add those runners to `INTERPRETERS`.
- **Outward entries also match by bare file name** — customer-delivery-web's `deploy/provision.sh` makes `.agents/provision.sh` ask, and `e2e/judge/cli.ts` makes any `cli.ts` ask. Match the bare name only after a `cd` into the listed directory.
- **Earlier satellites have not declared `dry_run_commands`** — after their next sync, TaxDrop, MemoGo, Parchi and Mailstation ask on every `<listed script> --dry-run`. Read each listed script's argument parser and declare only those that rehearse.
- **A global flag hides the verb for five deploy CLIs** — `wrangler --env prod deploy`, `fly -a app deploy` and like supabase, railway and netlify forms get no decision. Add each CLI's value flags to `VALUE_FLAGS`.

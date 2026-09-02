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
- **`.agents/config.json` is ignored but documented as a per-repository override** — writing-coach commits four hook disables that are genuine repo policy, and career-ops and claude-code-boilerplate carry no ignore line at all. Track it, or split policy from operator taste?

## Work

- **`session-wrap.sh` blocks under `codex exec`** — the command completes, then `request_user_input` fails because exec mode cannot answer the full-wrap/skip prompt. Detect exec mode and skip the prompt.
- **Nothing validates `.agents/codex/hooks.json`** — `codex mcp list` reads only `config.toml`, so a malformed hooks.json still exits 0. It is the other file that can fail a whole Codex session. Cover it with the `hooks/list` driver.
- **`research-mcp`'s robots.txt policy is unwritten** — it fetches on the caller's behalf without consulting robots.txt, as every reader tool does, and rate-limits per host. State the rule: user-directed single reads exempt, enumeration not.
- **`security-mcp`'s `check` repairs instead of failing** — it runs `build` before `check:bundle`, so a stale committed `dist/` is silently regenerated and passes. `research-mcp` omits `build` and fails loudly. Drop `build`.
- **`export-scaffold.py` leaves colloid-only passages in `.agents/README.md`** — the `fixtures/review-episodes/` row, the `../demo/` fragment, and the `.github/copilot-instructions.md` lines. A table row cannot take `<!-- colloid-only -->`; needs `SUBSTITUTIONS` or reordering.
- **`.agents/lsp.json` resolves language servers from PATH only** — a repository keeping its toolchain repo-local gets a server that never starts, silently. Give it `post-edit-check.sh`'s walk-up resolution, or state that LSP is PATH-only.
- **`export/gitignore-fragment` omits `/.playwright-mcp/`** — every satellite running a playwright server accumulates untracked, unignored session artefacts, which also makes `session-wrap.sh` read the tree as dirty. Add the line.
- **The root `AGENTS.md` Layers table names a symlink as canonical** — it lists `.claude/AGENTS.md` for the Claude adapter layer, but that path links to `.agents/claude/AGENTS.md`, and the same paragraph forbids editing through a symlink.
- **`.kimi/config.toml.example:55` gates `Bash` alone** — `.agents/claude/settings.json` gates `Bash|PowerShell|Monitor`. Check the Kimi hook docs, then widen the matcher or record that Kimi exposes no background shell. Codex has no Monitor.
- **Both MCP servers declare `node >=20.19.0`** — Node 20 reached end of life on 2026-04-30 and CI runs 22 and 24. Raise the floor to `>=22.0.0`, so the declared constraint names something supported and tested.
- **`ci.yml` duplicates the working-tree assertion across two jobs** — eight lines each, and two copies is where they drift. Factor it into a `.agents/` script both jobs call, which also carries it into the export kit.
- **`test-codex.sh`'s skip-Kimi branch never runs here** — this repository always ships `.kimi/config.toml.example`, so only a transplant exercises it. Add a stripped fixture the way `test-export.sh` builds its lean kit.
- **`decisions.md` has no shape lint** — `lint-breadcrumbs.py` gates breadcrumbs, nothing checks that each `### <id>` entry carries Decision, Why, and Reopens-when lines. Add the check when an entry first ships without one.
- **`ravi-travels` carries a stray `"SubagentStart": [{}]`** — an empty hook entry with no `hooks` key, left where the genome layer was stripped. Confirm the host ignores it, then check whether `export-scaffold.py` can emit it again.

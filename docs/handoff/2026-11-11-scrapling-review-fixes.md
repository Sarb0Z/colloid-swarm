# Scrapling entry: the review findings, planned

Workflow: Build · Stakes: Critical (the teardown gate, the MCP launch command,
a deny surface, and the host renderers).

**Gate: passed.** The operator chose the grilling step (`grill-me`) over a
plain OK, and confirmed the shared understanding after it on 2026-11-11. Its
rulings are below and in `.agents/decisions.md` (`scrapling-stealth-tier`,
`site-terms-on-operator-behalf`, `mcp-hosts-default-every-host`); its terms
(bot wall, access restriction, browser session, bounded run) are in
`GLOSSARY.md`.

The `scrapling-entry` run landed `6711d93` and `d3f1a11` on 2026-11-09. Three
Opus reviewers returned 14 findings that day; the lead session (`690d82d4`)
recorded the returns, then moved to other work, and applied none. The run
record has since been swept. The reports were recovered from that session's
subagent transcripts (`agent-a5f27d6e2f96f881b` gate, `agent-acef7ae6563e5e77c`
surface, `agent-af5ceee43017f210d` tests). Every finding was re-read against
`HEAD` on 2026-11-11 and still holds. A hostile review of this plan's first
draft (2026-11-11) returned three P1s and eleven P2s; the dispositions are in
the last section.

Containment: Scrapling is `enabled: false` in `.agents/mcp.json`, no account's
`.claude.json` registers it, `.mcp.json` lists only context7, playwright and
research-mcp, and `.opencode/opencode.json` carries only its five deny rules.
Every finding is latent until `python3 .agents/mcp.py enable scrapling`, which
the `search-and-cite` skill tells a session to run.

## Findings and dispositions

| ID | Sev | Finding | Disposition |
| --- | --- | --- | --- |
| S1 | P1 | `browser_open` and `browser_fetch_once` accept `executable_path` and `additional_args`, merged into Patchright's launch options: `executable_path="/bin/sh"` with `ignore_default_args` runs a shell command outside every shell guard; `record_har_path` writes cookies anywhere | Unit 1 |
| G2 | P1 | Closing one of several Scrapling sessions clears every stealth entry from that server; the second browser stops blocking Stop (`teardown-gate.sh:372-380`, `:582-586`) | Units 1 and 2 |
| G1 | P1 | `?close` with no stealth entry left for its server clears the whole `device` class, so a Scrapling `close_session` drops an Appium device (`:580-591`) | Unit 2 |
| T1 | P1 | The host-trigger test filters to `mcp__` names, so dropping `Bash` or `Monitor` from Claude's teardown matcher passes every suite | Unit 3 |
| S2 | P1 | `mcp_opencode.payload()` renders every `enabled` server, so enabling Scrapling puts it in OpenCode, where no hook runs, against the "Claude only" ruling | Unit 5 |
| T2 | P2 | The trigger test's tool list is hand-copied; a new gate class with no host trigger stays green | Unit 3 |
| T3 | P2 | No row asserts a Scrapling `close_session` leaves an Appium device | Unit 2 |
| T4 | P2 | The trigger test uses `rx.search`; every other matcher test uses `re.fullmatch` | Unit 3 |
| S7 | P2 | The five Scrapling denies have no remedy in `denied-tools.json`, no `denied-tool.sh` matcher, and are absent from `test-permissions.sh`'s `REQUIRED_DENY` | Unit 4 |
| S5 | P2 | `uvx --from scrapling[ai]==0.5.1` pins the top package only; dependencies re-resolve on a new machine | Unit 6 |
| S3 | P2 | Navigation through `browser_actions` or `browser_evaluate` reaches no sources-ledger row | Unit 7 (R1) |
| S6 | P2 | The `search-and-cite` route escalates to Scrapling on search results the agent picked, not only pages the user directed | Ruled allowed (R2); the route and the output style carry the new rule, unit 8 |
| S8 | P2 | `source_row` has no branch for `greptile` or registry-form `exa`, which the hook matcher fires for; capture "follows the registry" for the matcher only | Breadcrumb |
| M | — | `teardown-gate.sh` is 701 lines and its test 558; `mcp.py` 326; `normalize()` in `normalize-hook.py` about 130 lines; all over their marks before this work | Not this unit |

## Rulings (2026-11-11)

- **R1, the tool surface:** all twelve tools left after the denies stay
  callable, `browser_evaluate` included. The ledger records `browser_actions`
  and `browser_evaluate` calls: the browser session, the page it was on, and
  every web address found in the call, never the script body.
- **R2, which pages:** any public page the work reaches, read one at a time. A
  bounded run lets each agent read at most 25 pages of one walled site for one
  task, its count named in the report; never a crawl. A bot wall is any check
  in front of content the site sends to a reader with no login, a metered
  paywall and a login overlay included: the agent passes it and names it in
  one line. At an access restriction (a login or subscription the operator
  does not hold, or another person's account or data) the agent asks the
  operator how to go on: sign in with their own login, another source, or
  stop; it never gets past one itself. Unattended runs pass bot walls and list
  each in their report, and skip and report pages behind an access
  restriction.
- **Fetch addresses:** `http` and `https` only.
- **Hosts:** the `hosts` list stays; an entry without one renders on every
  host (not required), and Scrapling lists `claude` only.
- **Other hosts:** Claude Code is the host in use. Each Claude-only part this
  plan touches says so in one line where it is used; the full guide for
  adapting the scaffold to another host is deferred, its layout to be chosen
  after research.
- **Term:** "browser session" for Scrapling's open browser; "session" keeps
  meaning an agent session.

## Units

One commit each, in this order.

1. **The launcher narrows the server** — a new `.agents/scrapling-mcp.py`, the
   `scrapling` entry's `command` and `args` in `.agents/mcp.json`, regenerated
   host configs, a firing test, a CI step.
   - The registry launches `uvx --python 3.12 --exclude-newer
     2026-11-09T00:00:00Z --from 'scrapling[ai]==0.5.1' python -I
     ${REPO_ROOT}/.agents/scrapling-mcp.py`. `-I` is required: without it
     `.agents/` comes first on `sys.path`, and `.agents/mcp.py` shadows the
     `mcp` package Scrapling imports, so the server dies on every start
     (reproduced by the re-review). The launcher serves stdio as
     `scrapling.cli:mcp` does (`ScraplingMCPServer(...).serve(False, …)`,
     `cli.py:189-194`), from a subclass of `ScraplingMCPServer`. Scrapling
     registers each tool from the bound method through `functools.wraps`, so
     an override changes the schema the model is offered (reproduced).
   - `browser_open` and `browser_fetch_once` drop `executable_path`,
     `additional_args`, `cdp_url` and `new_context`, which only means
     something with `cdp_url`. `cdp_url` attaches to a running Chromium's live
     default context and its cookies. Their descriptions keep upstream's text.
     A call that still passes a dropped field has it ignored (reproduced).
   - The launcher overrides `_resolve_executable_path` to return `None`, and
     removes `SCRAPLING_EXECUTABLE_PATH` and `PLAYWRIGHT_NODEJS_PATH` from its
     environment before serving, so `mcp_env` in `.agents/config.json` cannot
     name a program either (`server.py:246-251`, Patchright's `_driver.py:15-18`).
   - `browser_open` makes `session_id` required, matching
     `[A-Za-z0-9_-]{1,64}` in full. Every open then names its session in
     `tool_input`, so the gate never needs the response.
   - The launcher removes the five denied tools with `remove_tool`, so no host
     offers them; the deny rules and unit 4's remedies stay as the second
     layer. R1's options (b) and (c) become launcher removals.
   - `browser_fetch_once` and `browser_fetch` accept only `http` and `https`
     URLs and refuse the cloud-metadata hosts `mcp_playwright.py:49-51`
     blocks for Playwright: a `file://` URL returned a local file's contents
     (reproduced).
   - Firing test, started from the real `.agents/` location with the command
     and arguments `mcp.py` resolves from the registry: `tools/list` shows the
     exact allowed parameter set and `required` for both tools, upstream's
     descriptions, and none of the five denied tools; a `file://` fetch is
     refused. CI gains an `astral-sh/setup-uv` step so the test gates here;
     where `uvx` is absent, as in a satellite without uv, it prints a visible
     skip and CI turns that into a notice, as `test-codex.sh` does. It joins
     `.agents/AGENTS.md`'s Verification list.
2. **Close only what a close names** — `.agents/hooks/policy/teardown-gate.sh`,
   `.agents/test-teardown-gate.sh`.
   - `+stealth` records `stealth <id> [server]` when `tool_input.session_id`
     passes `re.fullmatch(r"[A-Za-z0-9_-]{1,64}", …)` (not `re.match`, whose
     `$` admits a trailing newline), else `stealth unnamed [server]`. The ID keeps
     its full length; the pattern rules out tabs, newlines, backslashes and
     `]`, so no verdict line or awk field can be forged through it.
   - `+device` entries carry the `[server]` tag their tool name gives.
   - `?close <server> <id>`: drop the stealth entry with that ID and server.
     If none matches and that server's stealth entries are all `unnamed`, drop
     those. A close never drops a named entry it did not name, and never a
     device entry.
   - An Appium close (`APPIUM_CLOSE`) drops the `device` entries tagged with
     its own server.
   - Values reach awk through `ENVIRON`, not `-v`, which interprets
     backslashes.
   - Rows: two named sessions, close one, Stop still blocks naming the other;
     close it, Stop passes; a close naming an ID that matches nothing clears
     nothing; Appium device plus a Scrapling close, device stays (G1, T3); an
     Appium close clears its device and leaves stealth; one row through
     `.claude/hooks/adapter.sh` with a Claude-shaped payload.
   - Rows that change: `test-teardown-gate.sh:278-286` closes
     `mcp__stealthy__close_session` with no `session_id` and expects
     `a [stealthy]` cleared; under the rule above it clears nothing, and the
     row says so. The Stop text gains ` [server]` on device lines.
   - Not migrated: device entries recorded before this change carry no tag,
     and only a session that spans the upgrade holds one; it expires with its
     pending file.
   - `teardown-gate.sh` is embedded in the showcase: the commit carries the
     output of `python3 demo/embed-src.py` and `python3 .agents/port-public.py
     refresh`.
3. **The trigger test checks what it claims** — `test-teardown-gate.sh` only.
   - Assert each host's native names against its own teardown matchers:
     Claude `Bash|PowerShell|Monitor|TaskStop|KillShell|KillBash`, and its
     `EnterWorktree` PostToolUse group and PreToolUse `Bash|EnterWorktree`;
     Codex and Kimi `Bash`.
   - Assert every MCP regex the gate compiles matches at least one listed
     name. The regexes are read from the gate's text by matching its
     `re.compile(r"…")` literals; a gate edit that hides a regex from that
     reading fails the count check.
   - Switch to `re.fullmatch`. Read `.kimi/config.toml.example` only where it
     exists, as `test-codex.sh` does, so a kit exported without Kimi passes.
4. **Remedies for the five denies** — `.agents/hooks/lib/denied-tools.json`,
   the `denied-tool.sh` matcher in `.agents/claude/settings.json`,
   `test-permissions.sh`'s `REQUIRED_DENY`.
5. **Host lists, then Scrapling is Claude only** — two commits.
   - Refactor first: one optional `hosts` list per registry entry (`claude`,
     `codex`, `kimi`, `opencode`) replaces `codex_enabled` and `kimi_enabled`;
     an entry without one renders on every host, as the operator ruled over a
     required list. The readers that change: `mcp.py:25`,
     `:82` (`_validate_remote` excuses Codex's header limit when `codex` is
     not listed), `:97-98`, `:231` (Kimi), `:242-252` and `:268` (Claude's
     `.mcp.json` and `enabledMcpjsonServers`), `mcp_codex.py:7-12, 26`,
     `mcp_opencode.payload()`, the oracle in `test-codex.sh:89`, the fixtures
     in `test-mcp.sh:51-57`, `.agents/README.md:66`, and the embedded copies in
     the showcase, regenerated in the commit.
   - Off the list, each host renders what it renders today for an excluded
     server: Claude and OpenCode omit it, Codex omits it, and Kimi writes a
     disabled record. The type filters (an SSE server Codex and OpenCode
     cannot run) stay beside `hosts`. Expected render with every entry
     enabled, which the refactor must reproduce: context7, playwright,
     playwright-reader, appium-mcp, security-mcp, research-mcp, linear and
     greptile on all four hosts; atlassian on Claude and Kimi; exa on Claude,
     Kimi and OpenCode. New rows: a Kimi exclusion in `test-mcp.sh`, and an
     entry without `claude` that `.mcp.json` leaves out.
   - The validator's error for `codex_enabled` or `kimi_enabled` names
     `hosts`, and `export/README.md`'s sync steps gain one line: every
     satellite registry (19 carry the old fields, in their atlassian and exa
     entries) is migrated at its next sync.
   - Then `scrapling` lists `claude` only, with a `test-opencode.sh` row: with
     Scrapling enabled in a scratch registry, OpenCode renders no server and
     still renders the denies. The `scrapling-stealth-tier` decision's
     "Claude only" sentence names the field, and the registry description
     says "Claude only", since other hosts' session starts still list it.
6. **The pin is recorded** — the install command in the registry description
   and in `search-and-cite` gains the same `--python` and `--exclude-newer`
   flags as unit 1's launch. A `debt-log.md` entry: frozen dependencies miss
   security releases; reopened by a security advisory against any dependency
   or the next Scrapling version bump.
7. **The ledger records page-context calls** — `.agents/hooks/lib/sources-ledger.py`,
   the `scrapling` entry's `sources` in `.agents/mcp.json`, the matcher test.
   `browser_actions` and `browser_evaluate` become registry `sources`; each
   call writes a `browse` row naming the browser session, the page it was on
   (the last address the ledger recorded for that browser session), and every
   `http` or `https` address found in the call's input (a go-to action's
   address, a `fetch("…")` literal). The script body is never written. Rows:
   an evaluate with a fetch literal, an actions call with a go-to, a script
   carrying a token-shaped string that must not appear in the ledger.
8. **The wall rule lands** — `.agents/claude/output-style.md` line 11 (the
   rule every session reads), the Scrapling step of the `search-and-cite`
   route, and every other file that carries line 11's text, found with `rg`
   (the showcase embeds the style, so the commit carries its regeneration).
   - The line states R2 as ruled: any public page; one page at a time; the
     bounded run of 25 pages a site per agent per task, counted in the report;
     the sent-without-a-login test; the question at an access restriction and
     its three answers; unattended runs. The route carries the bound and the
     access-restriction question at the step where the agent picks Scrapling,
     and says the stealth browser is Claude only.
   - Tested before it lands, by `.agents/AGENTS.md`'s Writing contract
     language: pass conditions written first; at least two fresh headless
     runs on the model that reads it, from a fixture folder carrying the
     drafted style, for each of three prompts (a walled page reached through
     search proceeds and names the wall; a page behind someone else's login
     asks; a task needing 30 pages of one walled site stops at 25 and says
     so); graded from the transcripts' tool order and text.
   - Then the operator reinstalls the device policy (admin rights), with the
     command given in the report; until then session starts report the copy
     as stale.
9. **Breadcrumbs** for S8; for session starts on other hosts listing
   Claude-only servers (`hooks/lib/mcp-off.py:25-29` filters by no host); and
   for the guide to adapting the scaffold to another host, whose layout waits
   on research into how other agent scaffolds document host support.

## Options weighed

- **Where the launch options are refused.** A PreToolUse refusal in
  `denied-tool.sh` cannot fail closed: Claude Code runs the tool when a hook
  exits other than 0 or 2 or times out, the adapter runs the policy on an
  empty payload when normalizing fails, and the hook exits 0 when its toggle
  is off or its data file is missing. A launcher that removes the parameters
  holds in every one of those cases and on every host. Chosen: the launcher.
- **Identity or class for stealth clearing.** The gate's "CLEARING IS BY CLASS"
  comment rests on hosts not reporting which context a close reached.
  `close_session` names the session it closes, and the launcher makes every
  open name its session, so identity is available. Chosen: identity, with
  by-server clearing only for `unnamed` entries.

## Seams under test

- The launcher's `tools/list` test: catches the schema the model is offered;
  misses whether Scrapling's own `browser_open` behaves as before once
  called, which live QA covers.
- `test-teardown-gate.sh` rows on normalized payloads: catch the pending-file
  transitions; miss the shape real Claude sends.
- One adapter-level row through `.claude/hooks/adapter.sh` and
  `normalize-hook.py`: catches `tool_input` reaching the gate; misses
  real-session timing.
- `test-permissions.sh` rows: catch a dropped deny or remedy.
- `test-opencode.sh`, `test-codex.sh`, `test-mcp.sh`: catch each host's render
  after the `hosts` refactor.
- Live QA (below): catches the real paths; scarce (a browser download in a
  scratch copy), so it runs once, after units 1 to 6.

## The claim QA must reproduce

In a fresh Claude session in a scratch copy with Scrapling enabled through the
registry's exact command, started from the real `.agents/` location: the server
connects; the `browser_open` schema shows no `executable_path`,
`additional_args`, `cdp_url` or `new_context`, and requires `session_id`; a
call passing `executable_path` does not launch that program; no denied tool is
listed; a `file://` fetch is refused; two `browser_open` calls with IDs, then
`close_session` on one, and Stop still blocks naming the other; closing it
lets Stop pass; `python3 .agents/mcp.py enable scrapling` leaves no `scrapling`
server in `.opencode/opencode.json`. Also observe whether a `close_session`
that fails with an unknown ID fires PostToolUse or PostToolUseFailure. The
Appium cross-clear runs through the adapter with a crafted payload and is
reported as not run against a live device.

## Lenses

- Higher-level abstraction: removing the dangerous parameters from the schema
  makes the refusal problem disappear rather than guarding it; the same move
  removes the no-ID state by requiring `session_id`.
- Irreducible constraints: a resource blocks Stop until its own close is
  observed; a close clears only what it provably closed; a launch cannot name
  a program. Units 1 and 2 follow from these.
- Carve at the joints: what a call may pass (the launcher), what is open (the
  gate), which hosts run the server (the renderers), and what the tests claim
  (the trigger test), one commit each.
- Principal architect's rewrite: split the gate's embedded classifier from its
  awk replay, and `normalize()` by policy; not now, since both were over their
  marks before this work.
- Implicit state machines: a stealth entry is named or `unnamed`, then closed;
  a close that names nothing recorded is its own transition, and clears
  nothing.
- Concession drift: "it is off by default" settles none of S1, S2 or G2,
  because the skill tells sessions to enable it; R1 and R2 go to the operator
  rather than staying with the code's default reading.

## Dispositions of the plan review (2026-11-11)

| # | Sev | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | P1 | A PreToolUse refusal cannot fail closed | Accepted: the launcher replaces it (unit 1) |
| 2 | P1 | `normalize-hook.py` forwards only `tool_name` to `denied-tool.sh` | Moot: no argument refusal in a hook |
| 3 | P1 | The session ID read from `tool_response` rests on an unobserved shape, and `response_text` discards it | Accepted: `session_id` is required, read from `tool_input` |
| 4 | P2 | An untruncated ID can forge a verdict line or break awk fields | Accepted: the ID pattern, and `ENVIRON` (unit 2) |
| 5 | P2 | A close naming no entry could clear another live browser | Accepted: such a close clears nothing |
| 6 | P2 | The existing no-ID close row and untagged device entries | Accepted: listed under unit 2 |
| 7 | P2 | Argument entries in `denied-tools.json` would change every key's meaning | Moot: no argument entries |
| 8 | P2 | `cdp_url` attaches to a live browser's cookies | Accepted: dropped by the launcher |
| 9 | P2 | `opencode_enabled` would be the third copy of a per-host flag | Accepted: one `hosts` list (unit 5) |
| 10 | P2 | Unit 5 mixed the pin with the remedies | Accepted: remedies are unit 4, the pin unit 6 |
| 11 | P2 | Forwarding `tool_response` taxes every Bash call | Moot: nothing new is forwarded |
| 12 | P2 | Unit 2 missed the worktree triggers, read Kimi's file unconditionally, and named no regex extraction | Accepted: unit 3 |
| 13 | P2 | The bare date reads as local time, and Python was unpinned | Accepted: UTC time and `--python 3.12` (units 1, 6) |
| 14 | P2 | The plan did not state its gate or the grilling step | Accepted: the gate line at the top |

## Dispositions of the re-review of units 1 and 5 (2026-11-11)

Settled by running them: the override changes the schema; a dropped field is
ignored, not refused; the pinned environment resolves (49 packages, Python
3.12.15); `scrapling.cli:mcp` needs only `serve(False, …)`; `${REPO_ROOT}`
expands for all four hosts; no other tool takes a launch or path field.

| # | Sev | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | P1 | `python <file>` lets `.agents/mcp.py` shadow the `mcp` package; the server dies on start | Accepted: `python -I`, and the test starts the real path (unit 1) |
| 2 | P2 | CI has no uv, so the firing test either fails CI or never gates | Accepted: a setup-uv step, a visible skip elsewhere (unit 1) |
| 3 | P2 | The showcase embeds `mcp.py` and `teardown-gate.sh`; CI fails on stale copies | Accepted: units 2 and 5 carry the regeneration |
| 4 | P2 | Unit 5 missed readers of the two flags | Accepted: listed (unit 5) |
| 5 | P2 | "Off the list" means different things per host; no Kimi exclusion test | Accepted: per-host rule, the expected matrix, a Kimi row (unit 5) |
| 6 | P2 | Claude's `.mcp.json` is built inline, outside any renderer | Accepted: named, with a row (unit 5) |
| 7 | P2 | A missing `hosts` has no stated meaning, and satellites carry the old fields | Accepted: required field, a naming error, a sync step (unit 5) |
| 8 | P2 | `SCRAPLING_EXECUTABLE_PATH` and `PLAYWRIGHT_NODEJS_PATH` still name a program | Accepted: overridden and removed (unit 1) |
| 9 | P2 | Checking three absent names lets the override drift; `new_context` and descriptions | Accepted: exact parameter sets and descriptions (unit 1) |
| 10 | P2 | `re.match` with `$` admits a trailing newline | Accepted: `re.fullmatch` (unit 2) |
| 11 | P2 | The five denies stay host-enforced while launch options move into the server | Accepted: the launcher removes them (unit 1) |
| 12 | P2 | `file://` and metadata URLs reach local files and cloud metadata | Accepted: `http`/`https` only, metadata hosts refused (unit 1) |
| 13 | P2 | Other hosts' session starts list Claude-only servers | Deferred: breadcrumb, and "Claude only" in the description (units 5, 8) |

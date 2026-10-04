# Agent scaffold

`.agents/` owns the tool-neutral contracts. Host directories contain static
symlinks, adapters, or host-native persona files; they are not generated from a
second model registry.

## Ownership

| Canonical | Claude | Codex | Kimi |
| --- | --- | --- | --- |
| root `AGENTS.md` | `CLAUDE.md` link | native | native |
| `personas/*.md` | `.claude/agents/*.md` links | `.codex/agents/*.toml` static roles | generic dispatch |
| `skills/*` | `.claude/skills/*` links | native discovery | native discovery |
| `rules/*.md` | `.claude/rules/*` links | nearest `AGENTS.md` only | nearest `AGENTS.md` only |
| `hooks/policy/*` | Claude adapter | Codex adapter | Kimi adapter |
| `mcp.json` | `.mcp.json` | `.codex/config.toml` | `.kimi-code/mcp.json` |
| `lsp.json` | Claude plugins | none | none |

Run `python3 .agents/check-layout.py` after changing a persona, skill, rule, or
host link. It validates scaffold-owned links and leaves operator files alone.

## Personas and delegation

Personas are common paths, not a dispatch allowlist:

- `explorer` and `mechanic`: Haiku / Luna low
- `implementer`, `qa-verifier`, and `researcher`: Claude Sonnet 5 / Terra medium
- `reviewer`: Claude Opus 5 / Sol high
- `learning-reporter`: caller-selected; no dispatch default

Claude configuration lives in each persona's YAML frontmatter. Codex TOMLs
state the exact model and effort the caller passes at dispatch because Codex
does not consume Claude's per-agent tools, MCP, skill, memory, or hook fields.
Use a generic cell when no persona fits, with only the task's needed context and
capabilities.

## MCP state

`.agents/mcp.json` contains each server, description, and project `enabled`
state. Defaults are `context7`, `playwright`, and `research-mcp`; everything
else is off until requested.

This is a manual state-change command over the small project registry, not a
scheduled path. Run it when the registry or host state changes and at transplant.

```sh
python3 .agents/mcp.py
python3 .agents/mcp.py enable appium-mcp
python3 .agents/mcp.py disable appium-mcp
```

The tool writes host-native project files and preserves unrelated Claude local
settings. `enable` and `disable` change the tracked registry directly. Restart
the session after a state change because MCP clients connect at startup.

Disabled Codex records remain present to mask same-name user records. Unknown
user or plugin server names still merge normally; project config is not a
machine-wide allowlist. `codex_enabled: false` omits a provider-incompatible
record.

`sources` names the tools whose calls produce a source the provenance ledger
must record — a tool list, or `["*"]` for a server with no distinctive tool
name. `sources-matcher.py` builds every host's `sources-capture` hook matcher
from those declarations, so a server cannot be enabled without its capture
following it. Run it after changing a `sources` key; `--check` fails on drift
and `test-sources-matcher.py` gates it.

## Default browser

The `playwright` server launches branded Chrome with the config file
`.agents/.browser/playwright.json`. `mcp.py` writes that file from the
`browser` section of the ignored `.agents/config.json`. The tracked
`policy.json` must not set this section, and `mcp.py` refuses it there.
`config.json.example` shows each setting with its default. With no `browser`
section, the server keeps its own window and network. The profile does not
depend on the settings: when `.agents/.browser/profile` holds a synced cookie
store, the server uses that profile; otherwise it uses its own.

| Setting | Effect |
| --- | --- |
| `chrome_profile` | The Chrome profile directory that `browser-sync.py` reads. The default is `Default`. |
| `sync_sites` | The sites whose cookies `browser-sync.py` copies. |
| `user_agent`, `locale`, `timezone`, `viewport` | Browser context values. `null` keeps the value of the browser. |
| `headless` | `true` or `false`. `null` lets the server choose. |
| `proxy`, `proxy_env`, `proxy_bypass` | Send the browser traffic through a proxy. |

Do not set `user_agent` unless a site requires it. A user agent that does not
agree with the Chrome version makes bot detection more likely.

Run `python3 .agents/mcp.py` after you change a setting, then restart the
session. `mcp.py sync --settings FILE` reads the settings from FILE instead of
`config.json`.

### Sync your Chrome into the Playwright browser

The Playwright browser never drives your Chrome. It uses its own profile,
`.agents/.browser/profile`. `browser-sync.py` copies into that profile only the
cookies of the sites that you list. It copies no other data.

1. List the sites in `.agents/config.json`, for example
   `{"browser": {"sync_sites": ["zillow.com"]}}`. `zillow.com` includes
   `www.zillow.com` and the other subdomains. A subdomain entry also copies
   the domain cookies of its parent, because Chrome sends them to the
   subdomain. Those cookies work on every sibling subdomain too: `mail.google.com`
   copies the `.google.com` session cookies, which sign the agent in on all of
   `google.com`. It does not copy the host-only cookies of the parent or the
   cookies of a sibling.
   `localhost` and IP addresses match only themselves. The script converts an
   international name to the ASCII form that Chrome stores. It refuses any other
   single-label name and a small built-in list of public suffixes, such as
   `co.uk` and `github.io`. That list is not the full Public Suffix List, so
   list sites, not hosting domains.
2. Quit Chrome. Chrome writes new cookies to disk, such as the cookie from a
   solved challenge, when it quits. The script refuses to run while Chrome
   uses the profile.
3. Run the script yourself. In an agent session, use the `!` prefix:
   `! python3 .agents/browser-sync.py`. An agent must not run it: the
   destructive-command guard refuses it on Claude, Codex, and Kimi, unless
   `--source` points to a synthetic profile in a temporary directory. The
   refusal stays on when `hooks.guard_destructive.enabled` is `false`. The
   guard stops an accidental run. It does not stop a command that hides the
   script on purpose, for example `python3 -c` with `runpy`.
4. Restart the agent session.

To remove the synced cookies, delete `.agents/.browser/profile`, run
`python3 .agents/mcp.py sync`, and restart the agent session.

The script reads `~/Library/Application Support/Google/Chrome/<chrome_profile>/Cookies`.
Use `--source DIR` for a different Chrome user data directory. The cookie store
must be inside that directory: the script refuses a store that a symbolic link
puts outside it or into the default Chrome directory. The script
works on macOS only, because Chrome seals the cookies with the macOS Keychain
key. It prints the number of cookies for each listed site and the listed sites
that have no cookies. It never prints cookie names or values. It replaces only
the cookie store, so the other state of the Playwright profile stays. You can
run it again at any time.

An agent that uses the `playwright` server acts as you on the listed sites. It
can read the cookie values through the network and evaluate tools. Claude
denies `browser_run_code_unsafe` on this server. The deny rule removes the tool
from the main thread's list. A subagent whose `tools` names the server still
sees it, so `qa-verifier` removes it with `disallowedTools`.
`hooks/policy/denied-tool.sh` answers any remaining call with the reason and
the tools to use instead, read from `hooks/lib/denied-tools.json`. Its toggle
is `hooks.denied_tool.enabled`. Codex and Kimi have no
per-tool gate (debt `colloid-outward-gating-claude-only`). List only the sites
that the agent must use while you are signed in.

### Proxy

Set `browser.proxy` to `true`. Put the endpoint in the environment variable
that `proxy_env` names, `PLAYWRIGHT_PROXY` by default. Never put the endpoint
in a tracked file.

```sh
export PLAYWRIGHT_PROXY='http://user-session-{session}:password@proxy.example:8080'
python3 .agents/mcp.py
```

- `mcp.py` replaces `{session}` with a stored token. The browser then keeps
  one exit IP when the vendor supports sticky sessions.
  `python3 .agents/mcp.py sync --new-proxy-session` makes a new token.
- `mcp.py` stops with an error when `proxy` is `true` and the variable is not
  set, when the URL is malformed, and when a `socks5://` URL has credentials,
  which Chromium cannot send. The error never shows the URL.
- All traffic of the default browser goes through the proxy, and the vendor
  meters it. Loopback hosts (`localhost`, `*.localhost`, `127.0.0.1`,
  `[::1]`) always go direct. Other development hosts go to the vendor unless
  you add them to `proxy_bypass`.
- `mcp.py` reads the variable when it runs, not when the session starts. Run
  it again after you change the variable.

The config file and the token file are mode 0600 in `.agents/.browser/`. That
directory holds its own `.gitignore`, and `mcp.py` and `browser-sync.py` refuse
to write a file there that Git does not ignore.

Repository-owned servers under `mcp-servers/` ship committed `dist/` bundles so
clients can launch from a clean clone. After changing their source, run that
server's `npm run build` and `npm run check`.

## Hooks

Policies read normalized JSON from stdin. Host adapters translate event names
and payload shapes; they do not own behavior. `config.json.example` contains
hook defaults; a repository states its own policy in the tracked
`policy.json` — a hook it runs without, the scripts its publish guard must ask
about under `hooks.guard_publish.outward_commands`, and under
`dry_run_commands` the ones whose `--dry-run` really rehearses — and an
operator's ignored `config.json` overrides either per machine, except that it
can only extend the outward list and cannot declare a rehearsal.

`wait-gate.sh` refuses a main-agent Bash call, under Claude only, that waits
blind: sleeps longer than 5 s, a sleep that polls a background task's output
file, or a process started with a bare `&` and never waited for. Its denial
names the wait that ends when the thing happens — end the turn for work the
host reports on, `run_in_background` for a process the agent starts, a short
capped `until` loop for a condition. Calls the host already runs in the
background pass. Codex and Kimi have no background flag to point to, so the
gate is not wired there. The toggle is `hooks.wait_gate.enabled`.

`guard-publish.sh` also refuses, in every mode, a command that runs a script
writing to a hosted management API when that script is outside the
repository, untracked, or edited since the last commit, and inline code that
does the same (`hooks/lib/hosted-scripts.py`); the committed, unchanged script
asks like any outward mutation. No argument removes the refusal. The ask is
removed only for a script that `dry_run_commands` declares, and only when its
`--dry-run` is on: bare, followed by a word outside the boolean vocabulary, or
set to an on-value such as `true`. Any occurrence that is off, empty, or an
unknown `=` value makes the run live. Detection is textual — a management host and a
write signal in the file the command runs — so SDK clients and CLIs spawned
from a script are not seen. See decision `hosted-writes-need-committed-code`.

`worktree-provision.sh` runs at subagent start under Claude only: a cell that
starts inside a linked worktree gets that worktree's dependencies installed by
`.agents/provision.sh` before its first turn, and a failed install blocks the
start. The session's own directory is never provisioned, so an operator who
launches from a worktree keeps their `node_modules`. A worktree whose
lockfile matches the session checkout's byte for byte links that checkout's
`node_modules` instead of installing (`hooks.worktree_provision.share`,
default on; measured here 1 s and 9 MB against 54 s and 262 MB), and drops
the link before any real install once its lockfile changes. Installs run with
lifecycle scripts off; `hooks.worktree_provision.allow_scripts` turns them on
for a repository whose native modules need a build step, at the cost of
executing whatever a branch's lockfile names with no prompt and outside every
`PreToolUse` guard. Codex's hook set is hash-trusted and its subagents share
the checkout, and Kimi's `SubagentStart` is observation-only and cannot block
a start; on both, parallel writers go through `workloop.py`, which provisions
each lane itself.

`workloop-inbox.sh` turns the controller's durable inbox into push: at
subagent start a cell hears its host agent id and claims its lane with it;
between tool calls it hears each unread message for that lane once; at every
prompt and at session start the lead hears which lanes await review, carry
attention, are stale or broken, and when a run is ready to integrate.
Delivery is remembered in `.agents/.inbox-seen-<session>-<agent>`; the toggle
is `hooks.workloop_inbox.enabled`.

`parallel-writers-gate.sh` is the rail that makes that the default rather than
a choice: on Claude it watches every `Agent` dispatch, lets the first writer of
a turn through, and denies a second writer while another is live — in the same
message or still running in the background — unless its prompt is a workloop
brief. The denial names the three commands that turn the dispatch into a lane.
It also denies the lead's own `Edit` or `Write` while an uncoordinated writer
is live and no workloop run is active. Read-only personas never count; a
generic cell declares itself read-only by starting its prompt with
`READ-ONLY`; an unknown persona counts as a writer. An edit whose every target
lies outside the checkout passes. State lives in
`.agents/.writers-live-<session>`, `.agents/.writers-turn-<session>` and
`.agents/.writers-kinds-<session>` (the writer types each turn dispatched,
which decides whether a started cell registers); `session-start.sh` clears
them at startup and resume, and deleting the live
file is the manual reset for a cell known to have died. The toggle is
`hooks.parallel_writers.enabled`.

`claude/statusline.sh` is the status strip, wired as Claude's project
`statusLine`, so it replaces each person's own status line in every scaffold
repository. It draws two rows: the account badge, project, branch and dirty
count, lines changed, PR and session; then model, effort, the context fill,
the rate-limit windows and the output style. The badge comes from
`CLAUDE_PROFILE` when the launcher exports it, else from a `~/.claude-<name>`
config folder. It needs `jq`, and says so on the strip when `jq` is missing;
its icons need a Nerd Font. The toggle is `hooks.status_strip.enabled`.
Switched off in `policy.json` or `config.json`, it runs the person's own user
`statusLine` instead. See decision `status-strip-as-statusline-command`.

Codex hashes hook declarations. After changing `.agents/codex/hooks.json` or a
Codex hook command, inspect it and run:

```sh
python3 .agents/codex/trust-hooks.py "$(pwd)"
```

## Parallel work

For a durable, parallel implementation/review cycle, use the `workloop` skill
and `.agents/workloop.py`. It holds lane ownership, evidence, review references,
attention acknowledgements, and the QA completion gate in ignored runtime state;
it creates and provisions each lane's worktree, refuses a claim whose lockfiles
moved since the install, leases named exclusive resources between lanes,
verifies the merged lanes once with `integrate`, and removes what it created
with `teardown` — worktrees, branches it has landed, and Docker resources
labelled with the run and lane. A lane whose worker stopped without
submitting has its labelled resources reaped at the lead's next prompt. The controller is portable and exports
with the scaffold; it prepares prompts but does not attempt host-specific agent
dispatch.

How many cells a host will run at once is adapter-owned, not a property of the
subscription. `.agents/codex/config.toml` states the Codex cap; see
`.agents/codex/README.md`. Kimi's `AgentSwarm` ramps concurrency with no upper
limit unless `KIMI_CODE_AGENT_SWARM_MAX_CONCURRENCY` is set, so it needs nothing
here to run wide.

## Skills, rules, and stack packs

A skill's `SKILL.md` governs use; its `AGENTS.md` governs edits. Path rules live
in `rules/`. `stack-*.md` files additionally declare `detect:` markers so a
target cannot silently keep guidance for a framework it does not run.

```sh
.agents/lint-skills.sh
python3 .agents/check-stack-packs.py
```

## Verification

```sh
python3 .agents/check-layout.py
.agents/lint-skills.sh
.agents/test-lint-skills.sh
.agents/test-session-start.sh
.agents/test-workloop.sh
.agents/test-post-edit-check.sh
.agents/test-stop-investigate.sh
.agents/test-provenance-gate.sh
.agents/test-review-contract.sh
python3 .agents/lint-breadcrumbs.py
python3 .agents/test-sources-matcher.py
python3 .agents/test-guard-destructive.py
python3 .agents/test-wait-gate.py
.agents/test-session-wrap.sh
python3 .agents/test-guard-publish.py
python3 .agents/test-hosted-scripts.py
.agents/test-mcp.sh
python3 .agents/test-browser-sync.py
.agents/test-permissions.sh
.agents/test-statusline.sh
.agents/test-mods.sh
.agents/test-codex.sh
.agents/test-export.sh
# colloid-only
python3 demo/check-inventory.py
# /colloid-only
```

`test-review-contract.sh` runs `review-harness/bin/extract-contract.sh --check`,
which fails when `contract.md` differs from a fresh extraction of
`hostile-review.md`. Run the same script without `--check` to regenerate it.

`test-codex.sh` reports whether the installed Codex binary loaded the project
MCP configuration; syntax checks alone do not prove runtime discovery.

<!-- colloid-only -->
## Export

`export-scaffold.py` reads Git, removes repository-only genome and research
artifacts, and emits canonical plus host-native paths. Run it only from the
reviewed commit intended for transplant. The target-specific procedure is in
`export/README.md`.
<!-- /colloid-only -->

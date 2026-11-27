# Claude adapter

`.claude/settings.json` and `.claude/hooks/*` link here. The adapter normalizes
Claude hook payloads and passes JSON on stdin to engine-neutral policies under
`.agents/hooks/policy/`.

| Policy | Normalized fields |
| --- | --- |
| `guard-destructive.sh` | `project_dir`, `command` |
| `guard-publish.sh` | `project_dir`, `tool_name`, `tool_input`, `permission_mode`, `cwd`, `tool_use_id` |
| `post-edit-check.sh` | `project_dir`, `files` |
| `sources-capture.sh` | `project_dir`, `agent`, `tool_name`, `tool_input` |
| `session-start.sh` | `project_dir`, `source`, `session_id`, `transcript_path` |
| `session-wrap.sh` | `project_dir`, `stop_hook_active`, `session_id`, `transcript_path` |
| `provenance-gate.sh` | `project_dir`, `transcript_path`, `session_id` |
| `stop-investigate.sh` | `project_dir`, `stop_hook_active`, `last_assistant_message`, `transcript_path` |
| `research-prime.sh` | `project_dir`, `prompt` |
| `done-prime.sh` | `project_dir`, `prompt` |
| `ui-gate.sh` | `project_dir`, `event`, `session_id`, `tool_name`, `files`, `stop_hook_active` |
| `teardown-gate.sh` | `project_dir`, `event`, `session_id`, `tool_name`, `tool_input`, `stop_hook_active` |
| `iterm-attention.sh` | `project_dir`, `event`, `notification_type`, `session_id`, `transcript_path`, `last_assistant_message` |
| `pre-compact.sh` | `project_dir`, `trigger` |
| `worktree-sessions.sh` | `project_dir`, `event`, `tool_name`, `tool_input`, `cwd` |
| `style-inject.sh` | `project_dir` |
<!-- colloid-only -->
| `genome-inject.sh` | `project_dir`, `subagent_type` |
<!-- /colloid-only -->

`worktree-sessions.sh` (Claude only) keeps a session that enters a worktree under `.claude/worktrees/` listed by `/resume` in the repository root. It symlinks the worktree's folder in `~/.claude/projects/` to the root's, which rearranges the operator's session store outside the repository, so it is opt-in: `hooks.worktree_sessions.enabled` defaults off and is read from the session repository. An operator who wants it in every repository adds this command to user settings under PreToolUse and PostToolUse (matcher `EnterWorktree`) and SessionStart, with `<checkout>` the absolute path of a scaffold checkout:

```sh
[ -x "<checkout>/.agents/hooks/policy/worktree-sessions.sh" ] || { echo "worktree-sessions: no policy at <checkout>" >&2; exit 0; }; WORKTREE_SESSIONS_DEFAULT=true "<checkout>/.claude/hooks/adapter.sh" worktree-sessions.sh; exit 0
```

The guard keeps a moved or older checkout from reaching the adapter's missing-policy answer, which asks or denies on PreToolUse. A repository that says `false` in `policy.json` or `config.json` still wins, so a `config.json` copied whole from `config.json.example` turns the operator's registration off in that repository; delete the key there to inherit it. `python3 .agents/hooks/lib/worktree-sessions.py sweep --dry-run` lists folders that predate the hook. Never run `claude purge` on a worktree's folder: it follows the symlink to the root's history.

The device policy (below) appends `output-style.md`'s body to the end of every session's system prompt on a machine where `install-device-policy.sh` has run; a machine without it gets the root `AGENTS.md` but not the style. `settings.json` selects no output style, since selecting it as well puts the text in the prompt twice. `.claude/output-styles/colloid.md` links to `output-style.md` for an operator who selects it with `outputStyle` in `.claude/settings.local.json` on a machine with no device policy; `keep-coding-instructions: true` keeps the host's coding instructions then. `settings.json` sets `includeGitInstructions: false`, and the device policy sets it for every repository: the style says when to commit, and the host's built-in git section says otherwise; `.agents/playbooks/commits.md` carries that section's other rules. The host sends neither the style nor the device policy's appended prompt to a subagent, so `style-inject.sh` hands each one the style's body as SubagentStart context (`hooks.style_inject`). In the carrier, `session-start.sh` reports an installed copy — the device policy or the account's `output-styles/colloid.md` — that differs from this file. `.agents/codex/config.toml` mirrors the same text as `developer_instructions`, and `test-codex.sh` fails when the two drift. An operator who wants another style sets `outputStyle` in `.claude/settings.local.json`.

## Keeping edits on the Edit tool

`settings.json` sets `CLAUDE_CODE_THRIFTY_SONIC=0` in `env`. From Claude Code
2.1.238, auto mode routes file changes through the Bash tool — `sed`, heredocs,
short scripts — instead of Read and Edit. `ui-gate.sh` and `post-edit-check.sh`
register on `PostToolUse` for `Edit|Write|MultiEdit|NotebookEdit`, so a change
made through Bash matches nothing and both policies go quiet without failing.
A UI file was edited and shipped unlooked-at that way before this was set.

The flag reads through a tri-state parser, so `"0"` resolves to false rather
than to a truthy string. An explicit value wins over the release gate that
would otherwise turn the behavior on.

Keep it here and not in a shell profile. A machine-wide export would satisfy
the flag in a transplanted repository that never set it, so the harness would
look correct on one machine and be silently ungated everywhere else.

## Gating outward mutations

Two layers enforce `AGENTS.md` §External actions.

`guard-publish.sh` parses the shell command. It catches shapes that a prefix
rule cannot state, such as `git -C dir push`, `npx -p vercel vercel --prod`,
and a bare `vercel` that deploys with no verb. `config.json` can disable this
hook. A host without an ask-equivalent PreToolUse decision cannot run it.

`settings.json` `permissions.ask` matches a command prefix. This layer outranks
an `allow` entry and applies to subagent tool calls. It holds the plain forms
listed as `PLAIN_FORMS` in `test-guard-publish.py` when `guard_publish` is
disabled. It does not hold the shapes in the paragraph above. Do not read the
two layers as equivalent: with the hook off, coverage is the listed prefixes
only.

In auto, bypassPermissions and dontAsk modes no prompt reaches the user, so
`guard-publish.sh` denies instead of asking (`publish-guard-denies-where-no-prompt`
in `decisions.md`). The `publish-approval` mod (see Mods below) gives the user
an approval that reaches them in every mode. Before the call runs, it asks
`guard-publish.py` by argv whether it would ask. If so, it opens Claude Code's
own question dialog with the whole command, quoted so control characters show,
and the guard's reason; a command too long to show whole gets no dialog. "Run it" writes
`.agents/.publish-approved-<tool_use_id>`. The guard consumes that token within
120 seconds and answers "allow" on its ask path only. "Refuse" denies the call.
Anything else leaves the guard's answer standing: a dismissal, text typed under
Other, a dialog that resolved while the user was idle, or a run with no one to
ask. The hosted-write refusal never reads a token, and a deny from any other
hook, such as `guard-destructive.sh` on `git push --force`, still wins. With
`hooks.publish_approval.enabled` off, the guard reads no token and behaves as
described above. The token is a plain file, so it holds against the model's
mistakes, not against a model working to forge one (debt
`publish-token-forgeable`).

`test-guard-publish.py` asserts both directions. Every rule must name a command
that `guard-publish.sh` also treats as an outward mutation, so no rule prompts
on a benign command. Every plain form must have a rule, so disabling the hook
cannot silently drop one.

The `Artifact` rule names the whole tool, so the settings layer prompts on the
read actions that `ARTIFACT_READ_ACTIONS` lets through. On this host the hook's
read set therefore changes nothing for Artifact. That set still governs a host
that runs the hook without the settings layer, and it decides the reason text
the prompt shows.

`gh api` carries no rule. A prefix rule cannot separate a read from a write, and
a prompt on every read teaches the operator to approve without reading. The
parser inspects the method and gates the writes.

The `gcloud` and `firebase` writes are hook-only, except `firebase deploy`.
`gcloud` puts its verb at the end of a group path of any depth (`gcloud
services api-keys delete`), and `firebase` puts it after a colon namespace
(`firestore:delete`). A prefix rule cannot state either shape. A global flag
before the verb (`firebase -P prod deploy`) also defeats the one prefix rule.
With `guard_publish` disabled, no prompt gates these writes.

### MCP tools

Both layers above read a shell command, so an outward mutation issued through an
MCP tool reaches neither. `permissions.ask` covers those instead, because rule
order is deny, then ask, then allow: the rule still prompts after an operator
answers "don't ask again" for the same tool. `guard-publish.sh` stays out of the
MCP path — it would run on every documentation lookup and browser read to gate a
handful of calls, and the settings layer already outranks the rule it would race.

A registry server whose tools write to a remote system carries `"outward": true`
in `.agents/mcp.json`, and `test-mcp.sh` fails when one has no matching rule.
That keeps `python3 .agents/mcp.py enable <name>` from outrunning the gate.
Plugin and connector servers are not in the registry, so their rules are written
by hand. The three shipped here were copied from tool names observed in a live
session, not guessed. Check a new one the same way: a rule naming no known tool
normally warns at startup, but that check exempts names containing an
underscore, so every MCP rule is exempt and a typo is silent. `test-mcp.sh`
validates rule shape, which catches a wrong separator but not a well-formed
wrong name.

A prompt is the wrong answer for a call that destroys data, so `permissions.deny`
holds the destructive verbs — `delete`, `remove`, `destroy` — for each outward
server. Deny is evaluated first, and it removes the tool from the model's context
instead of offering it and refusing. That removes the reason text with it, so the
model cannot explain the refusal; the capability survives on the shell route,
where `vercel rm` still meets `permissions.ask` and the destructive-command
parser. Denying the MCP shortcut re-routes the operation through the gated path.

Every deny rule uses the one glob shape the host documents: a glob-free server
segment and a trailing star. `test-mcp.sh` rejects a wildcard anywhere else,
because nothing documents a mid-pattern match and a glob that matches nothing
fails open in silence. It also fails when a rule would match a read tool, which
is the failure a deny cannot announce — `drop` as a verb would take
`browser_drop` with it.

Slack and Google Drive stay at whole-server `ask` rather than deny. Both already
prompt on every call, and a Drive delete moves the file to the trash.

Two gaps stay open on purpose. A server marked outward is gated whole, including
its read tools, because tool names are only known once the server runs. And
`playwright` is not gated at all: a form submission or a click on a deploy button
is an outward mutation, but prompting on every navigation would train the
operator to approve without reading — the same reasoning that leaves `gh api`
to the parser.

Both layers stop at this repository. To cover every session on a machine, use a
Claude Code policy helper. `managed-settings.json` names an executable file.
The executable writes `{"appendSystemPrompt": ..., "managedSettings": ...}` to
stdout. `appendSystemPrompt` is the only key that adds text to the system
prompt without a command-line flag. Claude Code accepts this key from helper
stdout only, and rejects it in a static managed payload. `device/` holds that
kit and `install-device-policy.sh` installs it.

One machine can limit one signed-in account more than the others. A
machine-local file, `~/.config/claude-policy/account-limits.json` by default
(`CLAUDE_ACCOUNT_LIMITS` names another), maps an account email to the managed
settings it adds; only `deniedModels` is accepted, for example
`{"guest@example.com": {"deniedModels": ["fable"]}}`. The file is never
committed, because the accounts belong to the machine, not the scaffold.
`build.py` writes one full payload per account under `accounts/`, and the
helper serves it when the profile Claude Code starts with is signed in to that
account. It finds the profile through `CLAUDE_CONFIG_DIR`, or through
`CLAUDE_PROFILE` when Claude Code's environment scrub removed the first. To
lift a limit, delete the account's entry and install again; the installer
replaces the whole `accounts/` folder. The limit holds against normal use, not
against the account's user: anyone who can edit the profile's `.claude.json`
can change the email the helper reads, and a sign-in after start takes effect
at the next hourly refresh.

The adapter fails closed on an unknown or non-executable policy. Policies own
their behavior and exit contract; do not duplicate that logic here.

Every hook command and the `statusLine` command in `settings.json` finds its
script the same way. It looks in the launch folder first (`CLAUDE_PROJECT_DIR`),
then in the working folder and each folder above it, and it exports the folder
it found as `CLAUDE_PROJECT_DIR` so the policies read the right project. A
working folder under `<checkout>/.claude/worktrees/<lane>` maps back to the
checkout when the checkout holds the adapter, so an isolated cell shares the
checkout's parallel-writers ledgers. When nothing is found, a `PreToolUse` hook
prints the relaunch line and exits 2, which blocks every tool call, reads
included. Every other event prints the same line and exits 1, a visible notice
that blocks nothing, because exit 2 on a prompt, stop or compaction event would
erase the prompt, loop the agent or stop the compaction. The status line prints
`guards unavailable: relaunch Claude Code from inside the repository` and exits
0. Known residue: a session that moved from one scaffolded repository into
another runs the first repository's adapter and `policy.json` against the
second's hook list; per-session state (wrap, UI, teardown and writer ledgers)
follows the working folder, so it splits across repositories when the session
moves; after a `cd` out of every repository, every later tool call is blocked,
the `cd` back included, and only a relaunch recovers; a workloop lane
provisioned outside its checkout, such as in a product folder, resolves to its
own adapter; and a satellite whose `.claude/hooks/adapter.sh` link is dangling
moves, at its next sync, from silent exit-127 failures to every tool call
blocked; switching a session to a branch or commit that predates the scaffold
(no `.claude/hooks/adapter.sh`) blocks every later tool call, the switch back
included, until relaunch; and with nothing found, the walk tests every ancestor
up to `/`, so an `adapter.sh` under an ancestor's `.claude/hooks/`, including
Claude Code's own `~/.claude/hooks/`, would run as the repository's adapter
(`colloid-hook-lookup-walk-unbounded`).

`sources-capture.sh` deliberately receives the raw tool name and input. The
shared `sources-ledger.py` classifies native search/fetch, Context7, readable
fetch, open-access resolution, and browser navigation calls, so each host does
not carry a separate mapping. Unsupported or empty tool shapes write no row.

| Tool shape | Ledger row |
| --- | --- |
| `WebSearch` with `query` | `search`, query |
| `WebFetch`, `FetchURL`, or `*__fetch_readable` with `url` | `fetch`, URL |
| `*__browser_navigate`, `*__browser_fetch_once` with `url` | `browse`, URL |
| Scrapling `*__browser_fetch` with `url` | `browse`, URL; with `session_id`, `<URL> session=<id> [host=<host session>]` |
| Scrapling `*__browser_actions`, `*__browser_evaluate` with `session_id` | `browse`, `<page> session=<id> [host=<host session>] [<address> ...]`: the page is the session's last `browser_fetch` URL (`-` before one), the addresses are those in the call, never its script |
| `*__resolve_open_access` with `query` | `search`, query |
| Context7 `*__resolve-library-id` / `*__query-docs` with `query` | `search`, query |
| plugin Exa with `url`, otherwise `query` | `fetch` URL, otherwise `search` query |

## Mods

A mod is a Claude Code plugin whose hooks are a TypeScript module loaded once
into the session. The rule for what becomes one is
`mods-where-value-exceeds-portability` in `decisions.md`; the plan is
`docs/handoff/2026-10-02-claude-code-mods.md`.

Each mod lives in `mods/<name>/`: `.claude-plugin/plugin.json`,
`hooks/hooks.json`, `hooks/register.ts` (`register.tsx` when it draws with
JSX), and `tests/*.test.ts`.
`.claude/skills/colloid-<name>` links to it, because Claude Code loads a
plugin folder it finds under the project's `.claude/skills/`.
`check-layout.py` derives that link from the folder. Claude Code writes type
declarations into `.claude-plugin/types/` each time it loads a mod, and a
`tsconfig.json` extending them when it loads the folder through
`CLAUDE_CODE_PLUGIN_DIRS`; both are gitignored.

A mod reads its switch at session start through `hooks/lib/config.py`, so
`policy.json` and `config.json` switch it like a settings hook:
`hooks.<name>.enabled`. It runs existing Python policy by argv and never ports
it.

`test-mods.sh` runs `claude plugin validate` and `claude plugin test` on every
mod. Both run with no login. CI runs them against the Claude Code version that
`ci.yml` pins. A Claude Code release older than 2.1.287 loads no mods.

| Mod | What the user sees |
| --- | --- |
| `publish-approval` | A dialog before a push, deploy or publish, in every permission mode (see Gating outward mutations) |
| `inline-thinking` | Claude's thinking summaries in the collapsed transcript, dim and marked `∴`, between the rows they came between; opt-in (below) |
| `status-band` | The session status above the prompt in place of a status line: the status strip's rows, this task's cost, agent time, tests and callers open, and buttons to fold it to one line and copy the task (below) |

`status-band` draws, above the prompt, what the status strip drew: the account
badge, project, branch, dirty count, ahead and behind, lines changed, PR,
worktree, session name, duration and vim state; model, effort, thinking, fast
mode, the context fill, the 5-hour and 7-day limits and the output style; and
the unit readouts row from `readout.py strip`. A fourth row is this task's own:
its cost and the last turn's, turns, agent time, `tests pass`, `fail` or
`stale` (after a later code edit) from the last Bash command that ran a test
runner, and `N callers open`, the call and import sites
`removed-callers.py --json` finds for the definitions the task's Python edits
removed (`callers ?` when that check fails). `One line` folds the band to one
row and `Copy` puts the task on the clipboard as Markdown. A task starts over
at session start and at `/clear`.

Four values reach only the `statusLine` command: effort, fast mode, the live
vim state and the lines changed. `claude/statusline.sh` is therefore a silent
relay: while the band's marker `<session>.on` stands in
`${TMPDIR:-/tmp}/colloid-status-$USER/`, it copies the status JSON to
`<session>.json` there and prints nothing; otherwise the person's own user
`statusLine` runs. Idle, the band stats that file every 2 s and starts no
process; git (with `GIT_OPTIONAL_LOCKS=0`) and the readout reader run at
session start, at a prompt, after a Bash, Edit or Write, and when the relay
names another folder, and the reader only while `.agents/.readout/` exists.
The toggle is `hooks.status_band.enabled`, default on; switched off, or where
the band does not load (`claude -p`, an untrusted folder, a Claude Code without
mods), the person's own status line shows, and nothing shows for a person who
has none. Its icons need a Nerd Font.

`inline-thinking` draws what Claude Code shows only in the expanded view
(`Ctrl+O`, `--verbose`), which also expands every tool call. Each summary goes
above the tool call that follows it, else below the previous call's result or
the user's prompt, since those rows say which view they are in; under `Ctrl+O`
the mod draws nothing and Claude Code's own copy shows. A summary between two
replies or narration lines, or after a prompt with no typed text (an image
alone, a slash command), has no such row, so it draws above the next reply or
narration line and shows twice under `Ctrl+O`. The mod knows a row by its
opening 160 characters, so a summary beside a row that repeats an earlier one
("yes", "Done.") could belong to either and draws at neither; `Ctrl+O` still
shows it. A repeated prompt hides the summary as it is sent. A repeated reply
can show the older one above it until its next tool call or the end of the
turn, because the event that would catch it earlier (`session.append`) goes to
Claude Code's own security plugin first on a machine with managed settings,
and that plugin does not pass it to user plugins. It needs `showThinkingSummaries: true` in settings, without which the
API sends redacted thinking. It skips the narration lines Claude Code draws
itself (`· summary`) by the kind each thinking block's signature carries,
decoded as Claude Code 2.1.325 does; when a release changes that format,
narration shows twice or not at all, and `test-mods.sh` does not notice, since
its signatures are built to the old format.

It changes what every session in a repository shows, so it is opt-in:
`hooks.inline_thinking.enabled` defaults off and is read from the session
repository (its main checkout, for a worktree), once for each folder a session
runs in. As with `worktree-sessions.sh`, a `policy.json` or `config.json` there
that does not parse turns it off, and the transcript says so once. Unlike that
hook, it also runs outside git, where the session folder's own
`.agents/config.json` decides. An operator who wants it in every repository
adds these two entries to the `env` block of user settings, with `<checkout>`
the absolute path of a scaffold checkout; where `CLAUDE_CODE_PLUGIN_DIRS`
already names other folders, append this one after a `:`.

```json
"CLAUDE_CODE_PLUGIN_DIRS": "<checkout>/.agents/claude/mods/inline-thinking",
"INLINE_THINKING_DEFAULT": "true"
```

The first loads the mod in every session. In a scaffolded repository its
`.claude/skills/colloid-inline-thinking` link offers the same plugin name, and
Claude Code keeps the `CLAUDE_CODE_PLUGIN_DIRS` copy, the session-only plugin
taking precedence: the debug log records the link's copy as not loaded, and
nothing draws twice. The second turns it on wherever a repository is silent; a
repository that says `false` still wins, so a `config.json` copied whole from
`config.json.example` turns it off there. A moved checkout leaves a path Claude
Code skips with a warning in the debug log, and the session runs without it.

The registration loads the mod from the checkout's working tree, not from a
commit, and every interactive session watches that folder. An uncommitted edit
or a branch switch there therefore changes the mod in every session on the
machine at once, and a hook it breaks is reported in each transcript. A lane
that edits the mod in a worktree runs the checkout's copy, not its own, in its
sessions; `claude plugin test` on the worktree's folder tests its copy.

## Language servers

With the servers installed, every session in the repository gets the LSP tool
(go to definition, find references, symbol search, call hierarchy) for
TypeScript, JavaScript and Python. After each edit Claude also sees the type
errors the edit introduced, except under TypeScript 7's built-in server (below),
which offers them only on request, and Claude Code asks for none. Nothing is installed per account:
the `code-intelligence` plugin in `plugins/code-intelligence/` loads from the
checkout through its `.claude/skills/colloid-code-intelligence` link, as a mod
does, and `check-layout.py` derives that link from the folder. Claude Code
loads it only in a folder the operator has trusted; a session in an untrusted
folder, such as a headless run in a new directory, gets no servers.

| Language | Server | Install |
| --- | --- | --- |
| TypeScript, JavaScript | `scripts/typescript-server` chooses | `brew install typescript-language-server` |
| Python | `pyright-langserver` | `brew install pyright` |

`typescript-server` runs `typescript-language-server`, which uses the project's
own TypeScript, when `node_modules/typescript` holds TypeScript 5 at the
project root. Anywhere else, such as a clone before its install or a monorepo
whose root holds no TypeScript, it runs a TypeScript 7 compiler's built-in
server (`tsc --lsp --stdio`), the project's own `node_modules/.bin/tsc` before
one on `PATH`. Homebrew's `typescript-language-server` brings that compiler as
its `typescript` dependency. That server navigates but sends no type errors
after an edit; in a scaffold repository the post-edit `tsc --noEmit` check
still reports them. Its errors, as `tsc` reports them, can differ from the
project's: measured on seven satellites, they matched in three and gained one
or two in four, mostly `TS5102` for an option TypeScript 7 removed. `--probe`
prints the command it would run and starts nothing.

Install with Homebrew, not `npm install -g`: fnm keeps one global package set
per Node version, so a global npm install disappears in a project that pins
another version. At a Claude Code session start, `hooks/lib/lsp-missing.py`
names each language that has tracked files here but no server that can start,
with its install command, unless the plugin is switched off as below.

`settings.json` turns off Anthropic's `typescript-lsp` and `pyright-lsp`
plugins, which run the same servers, so a user who enabled them does not run
two servers for one file type. To turn this plugin off for yourself, add
`"enabledPlugins": {"code-intelligence@skills-dir": false}` to
`.claude/settings.local.json`; `policy.json` and `config.json` do not reach it,
because it has no hook to read them.

The plugin and `lsp.json` declare the same servers with the same extension
map; `test-lsp.py` fails when they differ, and `test-mods.sh` validates the
manifest with `claude plugin validate`.

## Personas

`.agents/personas/*.md` are Claude-native definitions linked at
`.claude/agents/*.md`. Their frontmatter directly names tools, model, effort,
MCP servers, and permission mode where applicable, and never a turn cap (see
`no-persona-turn-cap` in `decisions.md`). Edit the canonical persona and run
`python3 .agents/check-layout.py`; no generation step exists.

Models are deliberately explicit and use the host aliases `haiku`, `sonnet`,
`opus`, and `fable`. The Agent tool's `model` parameter accepts only those
aliases, so a versioned model id fails validation on a generic cell. Generic
delegation remains valid when no cached persona fits.

## Local state

`.claude/settings.local.json` is operator-local and gitignored. `.agents/mcp.py`
updates only `enabledMcpjsonServers`, preserving unrelated keys. MCP changes
take effect in a new session.

Use `.agents/test-session-start.sh` for SessionStart behavior and
`.agents/test-codex.sh` for the shared policy normalizers exercised through the
Codex adapter. Host-native Claude persona discovery has no non-interactive list
command in this scaffold; verify it from Claude's `/agents` UI after transplant.

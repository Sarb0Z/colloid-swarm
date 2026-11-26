# Debt log

Standing tradeoffs and deferred *decisions* — the "naive O(n³) here, fine until
N>10k, rework needs a spatial index" record. Committed, and pulled on demand when
you touch the code that carries the pointer. Not auto-surfaced; its sibling
`breadcrumbs.md` is the actionable queue, this is the reference.

Reference an entry from code as `debt: <id>` — the pointer goes inline, never the
reasoning. One `### <id>` heading per entry (a kebab slug, e.g.
`colloid-07-naive-scan`), with one line each for:

- **Condition** — what the code does now, and why it's acceptable today.
- **Trigger** — the observation that would justify paying it off.
- **Rework** — what the fix costs.

### iterm-tab-liveness-copies

- **Condition** — "this pid still runs `claude` with the recorded start, read under `LC_ALL=C TZ=UTC`" exists three times: `~/.local/bin/claude-tab-state` (`ps`, `is_running`), `.agents/iterm/bin/pane-run`, and `.agents/hooks/lib/process_start.py` with `worktree_records.stamp_state`. `pane-run` also copies the tab-id pattern and the config-folder split from `claude-tab-state`. Acceptable: `claude-tab-state` lives outside the repository (`~/.config/docs/TERMINAL-SPEC.md`, Unit 3), so `pane-run` cannot import it, and each copy is a few lines (review `2026-11-16-prompt-pane`, finding 10).
- **Trigger** — `claude-tab-state` changes its record format, its `ps` environment or its liveness rule; or a fourth copy appears.
- **Rework** — move `claude-tab-state` into `.agents/iterm/bin/` with `install.sh` linking it, and have `pane-run` import one shared reader; about 60 lines moved and the TERMINAL-SPEC Unit 3 paths updated.

### colloid-guard-destructive-honest-mistake-only

- **Condition** — `guard-destructive.sh` matches regexes against a raw command string, so it cannot stop shell indirection: `eval $(base64 -d <<<…)`, `R=$(echo rm); $R -rf /`, and `echo / | xargs rm -rf` all pass, verified. A regex over a Turing-complete shell cannot win that fight. Acceptable: the guard's threat model is the model's own honest mistake, not an adversary with shell access — an adversary who can run `Bash` has already won. The header does not say this, which invites the guard being read as a security boundary it is not.
- **Trigger** — anyone proposing the guard as a control against a hostile operator or a prompt-injected agent, or a satellite repository citing it as one.
- **Rework** — none available at this layer; the honest fix is to state the threat model in the header and in `README.md`'s "The invariant" section. Real containment needs a permission layer or a sandbox, not a pattern list. Separately, the *honest-mistake* set is closeable and is filed as work in `breadcrumbs.md`.

### colloid-wrap-concurrent-attribution

- **Condition** — `session-wrap.sh` measures the files this session's editor tools wrote and the commits HEAD gained during its shell calls (`edit-record.sh`); a change or commit no session recorded counts for the session that stops. Residual: a peer's commit landing during this session's shell call is credited here; a peer's shell-made edit to an unclaimed file lands in whichever wrap fires; a commit made by a shell call that exits non-zero, or by `rebase --continue` after a conflict, is unrecorded and falls to the stopping session; Kimi shares one HEAD snapshot across concurrent shell calls. Each gap adds review rather than hiding work.
- **Trigger** — a wrap that sends a review over a peer's work often enough to be skipped by habit.
- **Rework** — record shell writes by diffing the tree around each shell call, and record commits on the host's failure event once one is confirmed. ~60 lines.

### githook-variant-strip-anywhere

- **Condition** — `.githooks/commit-msg` strips attribution-variant lines anywhere in the message, not only in the trailer block; body prose that starts a line with "Authored by:" is eaten. Acceptable: such prose is rare and the strip is what delivers variant normalization.
- **Trigger** — a real commit loses a legitimate body line to the strip.
- **Rework** — locate the trailer block (e.g. via `git interpret-trailers --parse`) and confine the strip to it; ~40 lines plus tests.

### codex-mcp-transport-collision

- **Condition** — Codex merges user and project MCP records per key. If the same name uses stdio in one layer and HTTP in another, the merged record carries both transports and Codex rejects the workspace configuration. Project output cannot safely predict every user or plugin layer. Acceptable: every project record carries an explicit transport, `test-codex.sh` loads the effective configuration with a timeout, and the transplant guide makes that loader check mandatory.
- **Trigger** — `codex mcp list` rejects a workspace because another layer declares one of the project registry names with a different transport.
- **Rework** — add a read-only preflight over the effective user/plugin configuration when Codex exposes a stable enumeration API, or adopt a managed machine-wide allowlist.

### codex-network-proxy-fd-leak

- **Condition** — Codex 0.147.0 retains managed HTTP/SOCKS loopback listeners and MCP children across completed work in a long-lived process. One observed process held 170 listeners and reached numeric descriptor 255 under macOS's inherited soft limit of 256; hooks, child-process startup, and transcript persistence then failed with `Too many open files`. Acceptable only with containment: `repo-autonomous` is network-off by default, while `repo-localhost` enables exact loopback access for a short, explicitly selected QA session.
- **Trigger** — qualify each candidate Codex release once before adoption: run 200 sequential local-QA commands at the measured current cost of one HTTP/SOCKS listener pair per command and require the descriptor count to return to baseline after every command. This is one qualification run per candidate release, not a daily gate (runs/day: 0 normally; 1 on a qualification day).
- **Rework** — remove the profile split only after that regression passes on the supported Codex version; until then, exit the entire opt-in QA thread when its local-network work completes. Raising `ulimit` is headroom, not rework.

### research-01-duplicate-ssrf-tables

- **Condition** — `research-mcp/src/core/url-policy.ts` carries its own copy of the blocked-subnet tables and its own pinned-lookup transport, duplicating `security-mcp/src/core/policy/target-policy.ts` and `.../scanner/http-client.ts`. The verdicts genuinely differ — the scanner *requires* loopback or an allowlisted staging host, the reader *refuses* anything non-public — so only the address tables and the pinning technique are shared, not the policy. Acceptable: two callers, each server bundles to a self-contained `dist/`, and a shared package would have to be built and versioned for both.
- **Trigger** — a third server needing the same tables, or the two copies observed to disagree about a range.
- **Rework** — hoist `.agents/mcp-servers/shared-net/` as a sibling package holding the tables plus the pinned-lookup transport, and have both servers depend on it. Neither file appears in `security-mcp/UPSTREAM.json`'s `selectedInputs` or `modifiedUpstreamFiles`, so this touches no upstream-tracked file and does not complicate the fork's three-way merge; ~80 lines moved, plus a build wiring change in both servers.

### colloid-shell-writes-skip-post-edit

- **Condition** — a file written through a `Bash` heredoc or `sed -i` skips the lint gate entirely: `post-edit-check.sh` runs on `Edit|Write|MultiEdit|NotebookEdit`, and a shell redirect is none of them. Acceptable: the agent is told to use the editor tools, and a shell-written file is linted at the next editor write to it.
- **Trigger** — shell-written files reaching commits unlinted often enough to matter, or a generator that emits code through redirects.
- **Rework** — widen the PostToolUse matcher to the shell tools and derive the touched paths from the command, which needs the shell parse `guard-destructive.py` carries, on every edit. The cheap alternative is to state in the hook header that the gate covers editor writes only.

### colloid-post-edit-no-process-cap

- **Condition** — `post-edit-check.sh`'s `check` entry runs under `asyncRewake` with no per-session cap, so a burst of edits can leave several `tsc --noEmit` and `pyright` processes resident at once. Acceptable: dropping `--incremental` removed the shared-file corruption, which was the harmful half, and no session has been observed exhausting memory or descriptors.
- **Trigger** — a measured session where concurrent typecheckers exhaust memory or descriptors.
- **Rework** — a per-session cap keyed on a lock directory, ~30 lines. Held deliberately: the diff cannot state how many processes are concurrent, and a cap that fires wrongly is a gate that stops gating. Measure a real 200-edit session first.

### colloid-ui-gate-subagent-session-id

- **Condition** — `ui-gate.sh` and the session-wrap edit recorder key state on `session_id`. Claude Code passes a subagent's edits under the parent's id (observed 2026-10-11 on 2.1.296: a delegated `.tsx` write landed in the parent's `.ui-pending-` file); Codex and Kimi subagents are unobserved, so there a delegated edit may never reach the main Stop. Acceptable: the gate is a reminder, and the wrap falls back to unclaimed files.
- **Trigger** — routine delegated edits under Codex or Kimi, or a delegated UI change there shipping without its screenshot step.
- **Rework** — run one delegated edit on that host and read the state filename; if the id differs, key the PostToolUse half on `project_dir`.

### codex-trust-hooks-lost-update

- **Condition** — `trust-hooks.py` read-modify-writes `~/.codex/config.toml`, which Codex itself writes when the operator toggles a setting. `os.replace` prevents a torn file but not a lost update, and nothing serialises the two writers. Acceptable: the window is narrow, no loss has been observed, and Codex writes that file on operator action rather than on a schedule.
- **Trigger** — Codex writing the file on a timer or in the background, or an observed lost toggle.
- **Rework** — take an advisory lock around the read-modify-write, ~15 lines; it only helps if Codex takes the same lock.

### provision-pip-no-closure

- **Condition** — `provision.sh` treats a `requirements.txt` whose every requirement is `==`-pinned as a lockfile and installs it into a `.venv`. Such a file pins direct dependencies only; transitive ones resolve from the index at install time, so two lanes provisioned days apart can differ in a package neither branch names. Accepted because the alternative was no environment at all for a repository that ships this way, and lanes of one run provision minutes apart from the same index.
- **Trigger** — a lane's suite goes red on a package absent from both requirements files, or a repository adopts `pip-compile` / `uv pip compile` output (recognisable by `# via` provenance lines) — then the pin check should require the closure and this entry retires.
- **Rework cost** — ~15 lines in `pinned_requirements`, plus the target repository generating a compiled requirements file.

### publish-token-forgeable

- **Condition** — the `publish-approval` mod's approval is a plain file, `.agents/.publish-approved-<tool_use_id>`, and `guard-publish.py` turns its ask or deny into allow for that one call while `hooks.publish_approval.enabled` is on. A process the model started earlier, such as a background shell or a parallel subagent, can read a pending call's id from the session transcript on disk and write the file itself. That is most likely while the mod holds the call in its dialog: if the user then dismisses the dialog, the forged token still allows the call. Acceptable: the guard's threat model is the model's honest mistake, not an adversary with a shell (`colloid-guard-destructive-honest-mistake-only`), and forging takes a deliberate sequence of transcript reads and a file write that no honest mistake produces.
- **Trigger** — a transcript showing a model write or read a `.publish-approved-*` path, or the guard being relied on against a prompt-injected agent.
- **Rework** — make the writer one the model's processes cannot imitate: Claude Code's Bash sandbox with `denyWrite` on `.agents/.publish-approved-*` plus permission deny rules for Write and Edit on that path, or drop the guard-side allow and let the dialog only explain the deny. Either is a new review of the boundary, a few hundred lines with tests.

### gate-reads-cell-metadata

- **Condition** — `parallel-writers-gate.sh` links a started cell to its `READ-ONLY`, `NOTES-ONLY` or `OUTSIDE` marker (`OUTSIDE`: a workloop lane, or a cell with a `WORKSPACE` line) through Claude Code's own `<session>/subagents/agent-<agent_id>.meta.json`, whose `toolUseId` equals the dispatching Agent call's `tool_use_id` (observed on 2.1.286, 2.1.294 and 2.1.296). The file is not a documented interface. Acceptable: the gate fails closed where it matters, since a cell that is not a registered writer and has unreadable metadata is denied, and a registered writer keeps today's behavior with a stderr notice. Lanes and `WORKSPACE` cells are not registered writers, so they are among the denied. Codex and Kimi do not run this gate. The gate's sweep also reads each live writer's own transcript, `<session>/subagents/agent-<agent_id>.jsonl` beside the metadata (observed on 2.1.299): a writer whose last user or assistant record is a user text starting `[Request interrupted by user` leaves the live writers, since the user's Esc on a foreground cell fires no hook at all, and a writer that left after `StopFailure` or that sweep comes back when the transcript grows past its size at leaving with a user or assistant record that is neither an API error nor an interruption. An unreadable transcript or one ending in a partial line keeps the writer live.
- **Trigger** — a Claude Code release moves or renames that file or field, so marked cells, every workloop lane included, are denied every write, even in their own worktrees, or cease to be recognized; or it moves the cell transcript or rewords the interruption text, so an interrupted foreground writer keeps blocking until its session restarts; or a hook payload gains the dispatch id, or a hook fires for an interrupted cell.
- **Rework** — read the dispatch id from the payload and drop `cell_markers.py`'s metadata read; ~30 lines and a test row. A hook for an interrupted cell replaces the transcript sweep and the restore-on-growth rule; ~120 lines and five test rows.

### colloid-product-folder-switch-agent-writable

- **Condition** — an agent in acceptEdits or auto mode can write the ignored `.agents/config.json` and set `hooks.product_folder.enabled` itself, switching the product-folder grant on with no prompt. The file's other toggles only switch off guards inside the checkout; this one widens access outside it. Acceptable: the grant keeps its boundary, so a self-granted switch opens notes and never a checkout, a hidden path, an instruction file or a risky part, and no agent has been observed setting it.
- **Trigger** — an observed agent edit to that key.
- **Rework** — a PreToolUse deny on agent file-tool writes to `.agents/config.json`; ~10 lines plus a test row.

### fanout-rule-copies

- **Condition** — the rule that a run declared without `--verify` is finished once it holds a cell and every cell is back lives in three places: the controller's `completion_problems` (`workloop_main.py`), the digest's cell notes (`hooks/lib/workloop-inbox.py`) and the session start's lead-less close (`hooks/lib/worktree_runs.py`). The hooks import nothing from the controller, so a trimmed export without it still runs them. Acceptable: the copies disagree only on a run holding lanes and no `verify`, which only a run made before `--verify` was required can be.
- **Trigger** — a change to the fan-out rule, or a fourth reader of it.
- **Rework** — one pure `fanout_state(run)` in `hooks/lib`, which the controller loads as the hooks do; ~30 lines and the three callers' test rows.

### owed-record-lookups

- **Condition** — `owed.py`'s `review_states` runs one git call per review record and per critical-path file at each record's tip, so a push prompt's cost grows with records × files: 201 records and 6 files took 6.9 s (review harness-u4, finding 7). Acceptable: one record in `docs/reviews/` carries `Covers:` today, and a push with no remote reads at most 200 commits.
- **Trigger** — a push prompt that takes over a second, or about 50 records carrying `Covers:`.
- **Rework** — one `git cat-file --batch-check` pass over every `<tip>:<path>` pair and one `git diff --name-only` per record range, cached for the call; ~30 lines and a timing row in `test-owed.sh`.

### owed-shared-helpers

- **Condition** — `owed.py` (471 lines, a 70-line `main`) repeats three pieces other scaffold code carries: the glob translation (`owed.glob_regex`, `workloop_git._glob_regex`, `check-stack-packs.py`), the session key, which is the session id's `cksum` (`owed.cksum_key`, `edit-record.sh`, `session-start.sh`, `session-wrap.sh`), and the work-log check (`owed.worklog_flag`, and `session-wrap.sh` for Codex and Kimi). Acceptable: each copy is short with its own test rows, and `test-owed.sh` checks the shell's `cksum` key against `owed.py`'s (review harness-u4, finding 17).
- **Trigger** — a change to the glob syntax `critical_paths` or lanes accept, to how a session is keyed, or to the work-log rule; or `owed.py` passing 500 lines.
- **Rework** — a `hooks/lib/globs.py` the Python callers import, the key computed once by `edit-record.sh` and passed on, and the Codex and Kimi wrap reading `owed.py`'s work-log answer; ~60 lines.

### scrapling-pin-frozen

- **Condition** — the `scrapling` registry entry launches `uvx --python 3.12 --exclude-newer 2026-11-09T00:00:00Z --from 'scrapling[ai]==0.5.1'`, so every dependency resolves as it stood on that date, and a security release of any of them never arrives. Acceptable: the same environment on every machine is what the launcher's tool-surface test and the live QA measured, and the server is off by default and Claude only.
- **Trigger** — a security advisory against Scrapling or any package in its resolved environment, or the next Scrapling release worth taking.
- **Rework** — move the version and the date together in the entry's `args` and `description` in `.agents/mcp.json`, the install line in `skills/search-and-cite/SKILL.md` and `PINNED_ARGS` in `test-scrapling-launcher.sh`, the pin sentence of `scrapling-stealth-tier` in `decisions.md`, then rerun that test and the stealth tier's live check; a few lines, plus a browser download.

### scrapling-session-limits

- **Condition** — the ledger's Scrapling session rows (`page_of` in `hooks/lib/sources-ledger.py`) accept four limits. The page is the address of the session's last `browser_fetch`, so a click or an evaluate that navigates leaves it stale. An address keeps its query string, credentials in it included (userinfo is dropped). A call that fails (PostToolUseFailure) leaves no row, so a `browser_actions` that fails part-way with its effects kept is unrecorded. The matcher also runs the hook on every server's `browser_evaluate`, Playwright's included, which costs about 70 ms a call and writes nothing. Acceptable: the row's job is a trail of addresses read, the transcript holds the full call, and none of the four writes a wrong address.
- **Trigger** — an audit that needs the page after a navigating click, a credential seen in a ledger query string, a failed action sequence that must be traced, or Scrapling gaining a navigating action.
- **Rework** — record the page from the call's result in `source_row`, strip known credential parameters in `clean_url`, add a PostToolUseFailure trigger to the three hosts' hook files and the matcher, and key the matcher on the Scrapling server alone; about 40 lines and a test row each.

### showcase-prose-unchecked

- **Condition** — `demo/check-inventory.py` keeps a card for every hook and skill and the lede's counts true, and `demo/embed-src.py` keeps each source panel current; nothing compares a card's hand-written sentence with the code it describes. The 2026-11-13 audit found 40 false statements accumulated since August, and its review five more. Acceptable: a reader can open each card's source panel beside its sentence.
- **Trigger** — an audit that again finds a card contradicting its source, or an operator acting on a claim the code does not make.
- **Rework** — generate each card's description from a summary line its source carries (a docstring's first sentence), or give each card a checked quote; about 80 lines in `check-inventory.py` and a convention for the sources.

### worktree-records-local-stamps

- **Condition** — every worktree record stamp keeps `host`, [pid, `ps` start text in the writer's locale and zone], beside its zone-free `start` (`hooks/lib/worktree_records.py`), because a session started in a worktree or branch whose hooks predate `start` reads `host` alone against the main checkout's shared records. A stamp with no `start`, written before it or by such hooks since, is read as before, its text exactly against `ps` in the reader's locale and zone (`stamp_state`), and the first sweep that reads it live writes it again with `start` (`worktree_sweep.upgrade`). The same text reads live, and is written again, a stamp whose `start` reads gone: such hooks write one when a session resumes while their sweep holds its record, since their write-back replaces `host` and keeps the entry's old `start`. Acceptable: a live session leaves the text-only form at its first sweep, so only a zone or locale change with no sweep between reads such a session gone, once.
- **Trigger** — in one repository: its last sync names a base at or after the commit that added `start`, and no worktree or branch checked out there runs hooks from before it; for the carrier, `git worktree list` shows none.
- **Rework** — drop the text branch of `stamp_state`, `upgrade` and the start text in `host`, keeping the pid; about 25 lines, and the test rows that write text-only stamps.

### inline-thinking-full-reads

- **Condition** — the `inline-thinking` mod rereads the whole main conversation (`$.session.messages({ as: 'api' })`, up to 4096 messages with media inline) after every main-thread tool call and turn, and walks it again (`hooks/register.tsx` `refresh`, `hooks/anchors.ts` `collect`). Reads run one at a time with one more queued, only where a terminal draws, so a `claude -p` cell reads nothing. Acceptable: one walk is a pass over blocks with short string work, and the live sessions it was tested in showed no delay.
- **Trigger** — a session where tool calls visibly lag with the mod loaded, a conversation past 4096 messages losing its early summaries before a compaction, or a debug log showing reads queued back to back.
- **Rework** — keep the walk's state (the pending summaries, the keys below the last row, the row counts) in `$.state` and advance it from `session.append`, which hands each main-thread row before it is stored; keep one full read at `session.start` for a resume. About 80 lines, and firing tests that raise rows through `session.append`.

### tailscale-key-rotation

- **Condition** — contabo-hop's apt list for Tailscale trusts only the key shipped in `.agents/iterm/server/tailscale-archive-keyring.asc` (fingerprint 2596A99EAAB33821893C0A79458CA832957F5868), and `setup-server.sh` installs tailscale with `--no-install-recommends`, leaving out the `tailscale-archive-keyring` package that would carry a rotated key. Acceptable: the key has signed Tailscale's packages since 2020 and carries no expiry, and one source owns the trusted key (review of the server step, 2026-11-18, finding 8).
- **Trigger** — `apt-get update` on contabo-hop reports a signature error for pkgs.tailscale.com, or Tailscale announces a new repository key.
- **Rework** — fetch the new key, check its fingerprint against Tailscale's announcement, replace the shipped `.asc`, and run `apply`; a few minutes, no code change.

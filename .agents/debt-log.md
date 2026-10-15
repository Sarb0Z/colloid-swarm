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

- **Condition** — `parallel-writers-gate.sh` links a started cell to its `READ-ONLY` or `NOTES-ONLY` marker through Claude Code's own `<session>/subagents/agent-<agent_id>.meta.json`, whose `toolUseId` equals the dispatching Agent call's `tool_use_id` (observed on 2.1.286 and 2.1.294). The file is not a documented interface. Acceptable: the gate fails closed where it matters, since a cell that is not a registered writer and has unreadable metadata is denied, and a registered writer keeps today's behavior with a stderr notice. Codex and Kimi do not run this gate.
- **Trigger** — a Claude Code release moves or renames that file or field, so marked cells are denied or cease to be recognized; or a hook payload gains the dispatch id.
- **Rework** — read the dispatch id from the payload and drop `cell_markers.py`'s metadata read; ~30 lines and a test row.

### colloid-product-folder-switch-agent-writable

- **Condition** — an agent in acceptEdits or auto mode can write the ignored `.agents/config.json` and set `hooks.product_folder.enabled` itself, switching the product-folder grant on with no prompt. The file's other toggles only switch off guards inside the checkout; this one widens access outside it. Acceptable: the grant keeps its boundary, so a self-granted switch opens notes and never a checkout, a hidden path, an instruction file or a risky part, and no agent has been observed setting it.
- **Trigger** — an observed agent edit to that key.
- **Rework** — a PreToolUse deny on agent file-tool writes to `.agents/config.json`; ~10 lines plus a test row.

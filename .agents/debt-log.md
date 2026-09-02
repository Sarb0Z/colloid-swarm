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

### colloid-knowledge-index-markdown

- **Condition** — `.agents/knowledge/index.md` is a markdown bullet list, but it is the one record-shaped file in the store (date, kind, subject, summary) and the one meant to be scanned rather than read. Benchmarks on nested-data retrieval put YAML ahead of markdown on two of three models tested (GPT-5 Nano 62.1% vs 54.3%; Gemini 2.5 Flash Lite 51.9% vs 48.2%), so a YAML index may retrieve better. Acceptable: that test used deeply nested Terraform configs at stress volume, where this index is flat and currently one line; a larger study (9,649 trials, 11 models) found no significant aggregate format effect, and markdown costs fewer tokens.
- **Trigger** — the index passes a few dozen entries, or gains a field worth filtering on (staleness sweeps, per-competitor lookup) rather than reading top to bottom.
- **Rework** — convert `index.md` to `index.yaml`, update the write instructions in `market-researcher` step 11 and `search-and-cite`, and add a parser wherever it is read; ~40 lines, plus a YAML dependency for any non-model reader.

### colloid-guard-destructive-honest-mistake-only

- **Condition** — `guard-destructive.sh` matches regexes against a raw command string, so it cannot stop shell indirection: `eval $(base64 -d <<<…)`, `R=$(echo rm); $R -rf /`, and `echo / | xargs rm -rf` all pass, verified. A regex over a Turing-complete shell cannot win that fight. Acceptable: the guard's threat model is the model's own honest mistake, not an adversary with shell access — an adversary who can run `Bash` has already won. The header does not say this, which invites the guard being read as a security boundary it is not.
- **Trigger** — anyone proposing the guard as a control against a hostile operator or a prompt-injected agent, or a satellite repository citing it as one.
- **Rework** — none available at this layer; the honest fix is to state the threat model in the header and in `README.md`'s "The invariant" section. Real containment needs a permission layer or a sandbox, not a pattern list. Separately, the *honest-mistake* set is closeable and is filed as work in `breadcrumbs.md`.

### colloid-wrap-concurrent-attribution

- **Condition** — `session-wrap.sh` cannot tell which session authored a commit or a working-tree change, so two concurrent sessions in one working tree each measure the other's work: session B can be handed session A's files and told to review them. Acceptable: one working tree per session is the normal shape, both measures already read shared state (the tree, HEAD), and the wrap is a skippable prompt.
- **Trigger** — routine parallel sessions in one checkout, or a wrap that sends a hostile-review subagent over another session's diff.
- **Rework** — attribute work to a session (record each session's own commits as it makes them, or key the range on a per-session ref) and measure only what it authored; ~60 lines plus a new piece of per-session state, and it still cannot attribute the shared working tree.

### githook-variant-strip-anywhere

- **Condition** — `.githooks/commit-msg` strips attribution-variant lines anywhere in the message, not only in the trailer block; body prose that starts a line with "Authored by:" is eaten. Acceptable: such prose is rare and the strip is what delivers variant normalization.
- **Trigger** — a real commit loses a legitimate body line to the strip.
- **Rework** — locate the trailer block (e.g. via `git interpret-trailers --parse`) and confine the strip to it; ~40 lines plus tests.

### colloid-lint-skills-deletion-blind

- **Condition** — `post-edit-check.sh` drops paths that no longer exist (`[[ ! -f "$f" ]] && continue`), so deleting a skill's reference file never runs `lint-skills.sh`, and the dangling `SKILL.md` link it leaves behind goes unreported until the next unrelated edit to that skill. Acceptable: the linter catches it on any later edit to the same skill, and deleting a reference file is rare next to editing one.
- **Trigger** — a dangling link reaching a commit, or reference files being deleted often enough that "the next edit" is not soon enough.
- **Rework** — the hook needs the pre-edit path set to know which skill a deleted file belonged to; either derive the owning skill from the deleted path before the existence check, or have the linter sweep every skill when any tracked deletion appears; ~20 lines, and the derive-from-path route reintroduces the string surgery the linter exists to avoid.

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

### research-02-reader-tier-loses-branded-chrome

- **Condition** — the `playwright-reader` MCP entry runs Chrome for Testing, not branded Chrome, because Chrome removed `--load-extension` from branded builds at milestone 137 and now discards it silently (verified: uBO Lite blocks 0/4 trackers under Chrome 150, 2/4 under Chrome for Testing 151). Content blocking and the branded-Chrome fingerprint are therefore mutually exclusive, and the scaffold ships both tiers side by side so the agent picks per task. Acceptable: the plain `playwright` entry still runs branded Chrome, so nothing is lost — it costs a second browser server's tool surface in context.
- **Trigger** — bot-gating on the reader tier often enough that the reading win stops paying for the weaker fingerprint, or Chrome restoring extension side-loading to branded builds.
- **Rework** — either drop one tier and accept its loss, or drive a single browser and load the extension over CDP (`Extensions.loadUnpacked`, which needs a flag the MCP server does not expose today); the one-tier route is a registry edit, the CDP route needs upstream support.

### codex-tool-hooks-no-subagent-identity

- **Condition** — Codex `SubagentStart` and `SubagentStop` now carry `agent_id` and `agent_type`, so lifecycle context and exemptions work natively. Ordinary `PreToolUse` and `PostToolUse` payloads still omit both fields, and subagent hooks reuse the parent's `session_id`. Acceptable: safety and post-edit policies intentionally apply to every caller; source rows without identity say `unknown`. Only a future main/subagent-specific tool policy would be blocked.
- **Trigger** — a tool policy needs different main/subagent behavior, or Codex adds stable agent identity to ordinary tool-hook payloads.
- **Rework** — add the identity field to the normalized raw tool contract and only then implement a Claude-shaped selector; no transcript or environment correlation fallback. Roughly 30 lines once the upstream field exists.

### kimi-subagent-start-cannot-inject-context

- **Condition** — Kimi 0.31.1 exposes `SubagentStart`, but documents it as observation-only and discards its hook output before constructing the child's prompt. Wiring `genome-inject.sh` would therefore report success without treating the subagent. Acceptable: Kimi dispatch instructions prepend exactly one genome; Claude and Codex inject automatically.
- **Trigger** — Kimi documents and ships model-visible context from `SubagentStart`.
- **Rework** — map `agent_name` to `subagent_type`, register `genome-inject.sh`, remove Kimi's manual-prepend instructions, and verify the child transcript rather than hook stdout; roughly 15 lines plus native QA.

### colloid-outward-gating-claude-only

- **Condition** — `AGENTS.md` § External actions is enforced on Claude alone. `guard-publish.sh` forces the permission prompt on outward Bash calls and on every Artifact action outside its read set, `permissions.ask` covers the plain forms declaratively, and `permissions.deny` blocks the destructive MCP tools. Kimi and Codex are instruction-only: `.agents/codex/config.toml` gates by permission profile and network domain, and neither names a tool, so a destructive MCP call from Codex is ungated where the same call from Claude is denied. Acceptable: neither host exposes an ask-equivalent PreToolUse decision or per-tool MCP permissions, so there is nothing to wire to.
- **Trigger** — either host shipping a hook decision that can *ask* rather than only allow or deny, or per-tool MCP permissions.
- **Rework** — return the host's ask shape from the existing policy scripts; the decision logic is already engine-neutral, so this is an adapter change, roughly 20 lines per host.

### colloid-shell-writes-skip-post-edit

- **Condition** — a file written through a `Bash` heredoc or `sed -i` skips the lint gate entirely: `post-edit-check.sh` runs on `Edit|Write|MultiEdit|NotebookEdit`, and a shell redirect is none of them. Acceptable: the agent is told to use the editor tools, and a shell-written file is linted at the next editor write to it.
- **Trigger** — shell-written files reaching commits unlinted often enough to matter, or a generator that emits code through redirects.
- **Rework** — widen the PostToolUse matcher to the shell tools and derive the touched paths from the command, which needs the shell parse `guard-destructive.py` carries, on every edit. The cheap alternative is to state in the hook header that the gate covers editor writes only.

### colloid-post-edit-no-process-cap

- **Condition** — `post-edit-check.sh`'s `check` entry runs under `asyncRewake` with no per-session cap, so a burst of edits can leave several `tsc --noEmit` and `pyright` processes resident at once. Acceptable: dropping `--incremental` removed the shared-file corruption, which was the harmful half, and no session has been observed exhausting memory or descriptors.
- **Trigger** — a measured session where concurrent typecheckers exhaust memory or descriptors.
- **Rework** — a per-session cap keyed on a lock directory, ~30 lines. Held deliberately: the diff cannot state how many processes are concurrent, and a cap that fires wrongly is a gate that stops gating. Measure a real 200-edit session first.

### colloid-guard-publish-unbounded-input

- **Condition** — `guard-publish.sh`'s matched shell path imports the 411-line destructive-command parser on every call, with no runtime or input ceiling. Acceptable: no trace shows a harmful bound, and a ceiling chosen without one would either never fire or fire on a legitimate payload.
- **Trigger** — a session where the gate's runtime is visible, or a payload large enough to matter.
- **Rework** — measure representative invocation counts and payload sizes, then set the ceiling from that measurement; the ceiling itself is about five lines.

### colloid-publish-gate-hook-half-unmeasured

- **Condition** — the publish gate's declarative half is measured: a user-tier `permissions.ask` rule beat a project `allow` for the same command, recorded in `knowledge/research/2026-08-21-claude-code-system-prompt-and-permission-tiers.md`, so an allowlisting operator is covered whatever the hook does. The hook half alone is unmeasured on the shapes no prefix rule states — `git -C dir push`, `npx -p vercel vercel --prod` — and the permissions documentation is silent on whether a hook `ask` overrides an `allow` entry. Acceptable: the two halves overlap, so the unmeasured one is redundant coverage rather than the only coverage.
- **Trigger** — removing either half, or an operator allowlist entry the hook is expected to override.
- **Rework** — run those two commands in a live session with matching allow entries and record the result. A measurement, not a code change.

### colloid-artifact-permission-specifier

- **Condition** — whether Claude Code's `Artifact` tool accepts a permission specifier (`Artifact(publish:*)`) or only the bare tool name is unchecked, so `permissions.ask` carries the bare rule and prompts on the four read actions `ARTIFACT_READ_ACTIONS` deliberately allows. Acceptable: prompting on a read is a nuisance, not a hole.
- **Trigger** — prompt fatigue on read-only calls. The realistic path is an operator adding a blanket allow and losing the mutating gates with it.
- **Rework** — test the specifier in a live session, then narrow the rule to the five mutating actions; one settings line if it works.

### colloid-ui-gate-subagent-session-id

- **Condition** — `ui-gate.sh` keys pending edits on `session_id`, and whether a spawned subagent's PostToolUse payload carries the parent's id is unobserved. A delegated UI edit may therefore never reach the main Stop. Acceptable: UI edits are usually made in the main session, and the gate is a reminder rather than a correctness check.
- **Trigger** — routinely delegating `.tsx` edits, or a delegated UI change shipping without its screenshot step.
- **Rework** — run one delegated edit and read the `.agents/.ui-pending-*` filename; if the id differs, key the PostToolUse half on `project_dir`. A one-line change behind a one-session measurement.

### codex-trust-hooks-lost-update

- **Condition** — `trust-hooks.py` read-modify-writes `~/.codex/config.toml`, which Codex itself writes when the operator toggles a setting. `os.replace` prevents a torn file but not a lost update, and nothing serialises the two writers. Acceptable: the window is narrow, no loss has been observed, and Codex writes that file on operator action rather than on a schedule.
- **Trigger** — Codex writing the file on a timer or in the background, or an observed lost toggle.
- **Rework** — take an advisory lock around the read-modify-write, ~15 lines; it only helps if Codex takes the same lock.

### codex-roles-cannot-enforce-tool-allowlists

- **Condition** — Codex custom roles cannot express the Claude persona tool allowlists, and Kimi has no generated persona routing at all. A delegated cell on either host is bounded by its handoff and the sandbox, not by a capability list. Acceptable: the sandbox is the real containment on all three hosts, and the allowlist is defence in depth.
- **Trigger** — either host exposing a project-scoped capability boundary.
- **Rework** — generate host-native role definitions from `personas/*.md`, the way `.claude/agents/*.md` are linked today.

### codex-eight-threads-unobserved

- **Condition** — `[agents] max_concurrent_threads_per_session = 8` is accepted by the host loader (`codex mcp list` passes in `test-codex.sh`), but no live session has opened eight spawned threads. Two things stay unknown: whether Codex opens all eight concurrently, and whether the ChatGPT plan throttles behind the raised cap. Acceptable: a cap higher than the service allows costs nothing, because the service-side limit binds first.
- **Trigger** — a Codex session that stalls below eight threads. It is evidence only if its queuing or usage errors are read: a service limit never surfaces as a thread count.
- **Rework** — dispatch eight bounded cells from one Codex thread and record which limit binds. A measurement, not a code change.

### colloid-check-bundle-not-symlink-safe

- **Condition** — `.agents/mcp-servers/*/scripts/check-bundle.mjs` is not symlink-safe. esbuild bakes realpath-resolved `node_modules/...` module comments into the bundle, so verifying reproducibility against a symlinked `node_modules` yields a mismatch that is an artefact of the link rather than of the source. Acceptable: neither server's install symlinks `node_modules`, and CI installs fresh.
- **Trigger** — a pnpm-style store or a workspace layout that symlinks `node_modules` for either server.
- **Rework** — normalise the realpath prefixes out of the bundle before hashing, ~20 lines; it weakens the check by exactly the bytes it erases.

### colloid-showcase-cards-handwritten

- **Condition** — `demo/scaffold-showcase.html` cards are hand-written. `embed-src.py` refreshes the source panel inside a card that exists and is silent about one that does not, so adding a hook or a skill costs a hand-authored card plus a `MANIFEST` line. Acceptable: `demo/check-inventory.py` fails CI on the gap, so drift is caught rather than shipped.
- **Trigger** — the hand-authoring step being skipped often enough that the CI failure becomes routine, or the card body gaining structure worth generating.
- **Rework** — generate the card from its manifest entry: ~60 lines in `embed-src.py` plus a template, and the hand-written prose in each card has to move into the manifest.

### colloid-knowledge-grades-unenforced

- **Condition** — the `[P]`/`[S]`/`[?]`/`[A]` source grades are unenforced, and two entries predate `[A]`. `2026-08-06-agent-knowledge-base-patterns.md:29` grades an in-house inference `[S]`, which is the laundering `[A]` exists to stop, and the "always say which kind" rule for `[?]` is ignored at `:74` and at `2026-08-07-...:52,:58`. Acceptable: knowledge entries are dated observations and must not be revised to match later facts, so a wrong grade stays until a superseding entry carries the correction.
- **Trigger** — a new entry superseding either file, or enough entries that a reader cannot spot a mis-grade by eye.
- **Rework** — a linter over the grade marks in `knowledge/`, plus writing the correction into whatever entry supersedes those two; ~40 lines and one entry.

### scalability-audit-no-metastable-law

- **Condition** — `scalability-audit` has no law for positive feedback under degradation: load rising as capacity falls, so the system stays broken after the trigger clears. The class is real and citable (metastable failure: HotOS '21, OSDI '22, HotOS '25), and the mechanisms, taxonomy and remedies are written up in `.agents/knowledge/research/2026-08-13-occupancy-and-metastable-failure.md`. Acceptable: no ex-ante detection question exists, and the literature calls that an open problem as of 2025. A law without a detection question is a slogan.
- **Trigger** — a detection heuristic worth standing behind, from the literature or from our own incidents.
- **Rework** — one law entry with its detection question and remedy shape; everything but the detection question is already written.

### colloid-cache-prefix-vs-long-context

- **Condition** — no vendor guidance reconciles cache-prefix placement, which wants stable content first so the prefix hashes identically, with long-context guidance, which wants data before the query. The two order the same bytes differently once both corpora are large near a 1M window. Acceptable: the scaffold ships no prompt carrying two large corpora, so the conflict is theoretical.
- **Trigger** — shipping a prompt that carries both a large stable corpus and a large per-call corpus near the window limit.
- **Rework** — measure both orders on the real prompt and choose per prompt. The answer is likely prompt-specific, which makes this a measurement habit rather than a rule.

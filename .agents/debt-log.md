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

- **Condition** — `sync-codex.sh` emits every MCP record with its transport, because Codex rejects a record that carries none unless a lower layer supplies one. Codex merges the TOML layers — user, project, and `-c` overrides — per key, so when another TOML layer declares the same server name with the other transport, the merged entry holds both a `command` and a `url` and Codex refuses to load the entire workspace configuration — every server, every hook, every setting. Enabled records carry the same hazard, so no emit shape avoids it. A configured server replaces a same-name plugin catalog entry outright, so plugins cannot produce this. Acceptable: it needs a same-name server with a different transport in the operator's own user config, `check-mcp-conflicts.py` warns on every sync when that condition holds, and `test-codex.sh` catches the missing-transport failure by running `codex mcp list` against the generated file.
- **Trigger** — a real workspace fails to load because a user or plugin config declares one of the registry names with a different transport.
- **Rework** — either drop the record when the merged result would conflict, which needs the generator to read `~/.codex/config.toml` and every plugin's config and re-check on each change, or a managed MCP allowlist if Codex grows one.

### research-01-duplicate-ssrf-tables

- **Condition** — `research-mcp/src/core/url-policy.ts` carries its own copy of the blocked-subnet tables and its own pinned-lookup transport, duplicating `security-mcp/src/core/policy/target-policy.ts` and `.../scanner/http-client.ts`. The verdicts genuinely differ — the scanner *requires* loopback or an allowlisted staging host, the reader *refuses* anything non-public — so only the address tables and the pinning technique are shared, not the policy. Acceptable: two callers, each server bundles to a self-contained `dist/`, and a shared package would have to be built and versioned for both.
- **Trigger** — a third server needing the same tables, or the two copies observed to disagree about a range.
- **Rework** — hoist `.agents/mcp-servers/shared-net/` as a sibling package holding the tables plus the pinned-lookup transport, and have both servers depend on it. Neither file appears in `security-mcp/UPSTREAM.json`'s `selectedInputs` or `modifiedUpstreamFiles`, so this touches no upstream-tracked file and does not complicate the fork's three-way merge; ~80 lines moved, plus a build wiring change in both servers.

### research-02-reader-tier-loses-branded-chrome

- **Condition** — the `playwright-reader` MCP entry runs Chrome for Testing, not branded Chrome, because Chrome removed `--load-extension` from branded builds at milestone 137 and now discards it silently (verified: uBO Lite blocks 0/4 trackers under Chrome 150, 2/4 under Chrome for Testing 151). Content blocking and the branded-Chrome fingerprint are therefore mutually exclusive, and the scaffold ships both tiers side by side so the agent picks per task. Acceptable: the plain `playwright` entry still runs branded Chrome, so nothing is lost — it costs a second browser server's tool surface in context.
- **Trigger** — bot-gating on the reader tier often enough that the reading win stops paying for the weaker fingerprint, or Chrome restoring extension side-loading to branded builds.
- **Rework** — either drop one tier and accept its loss, or drive a single browser and load the extension over CDP (`Extensions.loadUnpacked`, which needs a flag the MCP server does not expose today); the one-tier route is a registry edit, the CDP route needs upstream support.

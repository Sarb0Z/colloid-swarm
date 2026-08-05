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

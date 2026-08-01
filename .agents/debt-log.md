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

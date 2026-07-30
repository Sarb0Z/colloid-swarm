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

### githook-variant-strip-anywhere

- **Condition** — `.githooks/commit-msg` strips attribution-variant lines anywhere in the message, not only in the trailer block; body prose that starts a line with "Authored by:" is eaten. Acceptable: such prose is rare and the strip is what delivers variant normalization.
- **Trigger** — a real commit loses a legitimate body line to the strip.
- **Rework** — locate the trailer block (e.g. via `git interpret-trailers --parse`) and confine the strip to it; ~40 lines plus tests.

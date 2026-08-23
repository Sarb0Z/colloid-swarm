# Scaffold transplant investigation

## The question

Can the current colloid-swarm scaffold be transplanted onto mail-platform,
writing-app, field-crm, claims-app, and product-48 without overwriting target
work or changing user-wide Codex trust settings?

## Findings

- The canonical export completed from `HEAD` into an isolated kit. It dropped
  16 Colloid-only paths, stripped marked regions from 16 files, and generated
  four debt-log seed entries.
- The five targets were located at:
  `mail-platform/mail-platform`, `writing-app`, `field-crm-product/field-crm`,
  `claims-org/claims-app`, and `product-48/product-48`.
- Existing dirty product/operator files were inventoried and preserved. The
  transplant was not committed and Codex trust activation was not run.
- Shared scaffold runtime files were merged into all five repositories. The
  generated debt entries were appended only where absent.
- Stack-specific additions were made for Rails in field-crm, Next.js in
  claims-app, and Next.js plus Expo in product-48. Missing `qa-verifier` was
  added to mail-platform. field-crm received the repository-owned research and
  security MCP bundles because it had no project MCP registry.
- Layout verification passed for mail-platform (59 links), writing-app (65),
  claims-app (64), and product-48 (69). field-crm's real pre-existing host
  integration is incompatible with the canonical symlink contract, so its
  layout check remains blocked without replacing target-local host files.
- Skill and stack checks passed for mail-platform (12 skills), writing-app (14),
  claims-app (13), and product-48 (14; two stack packs). field-crm's existing 26
  target-local skills lack required `AGENTS.md` files and several reference
  files lack contents tables; those files were intentionally not rewritten.
- Session-start verification passed for mail-platform. Its MCP registry was
  replaced with the canonical schema; MCP registry tests and Codex host-loader
  integration checks now pass.

## Ruled out

- Blind `rsync --delete` was not used. It would risk deleting target-local
  skills, debt, memory, and operator state.
- Canonical MCP reset was not applied. Existing target registries and their
  arguments were preserved.
- `trust-hooks.py` was not run. The repository exposes the trust tooling, but
  user-wide Codex trust choices were left unchanged.
- field-crm's existing `.claude`, `.codex`, `.github`, and legacy Rails skill
  library were not replaced merely to make the canonical layout check green.

## Open questions, risks, and next step

1. field-crm needs a separate host-integration migration if its real files are to
   become canonical symlinks. Its legacy skill library also needs a bounded
   governance migration before the canonical skill lint can pass.
2. The target repositories contain uncommitted transplant diffs by design.
   Review and commit each target separately after the two decisions above.

Recommended next step: review and commit each target separately, leaving
field-crm as an explicitly partial transplant until its host-layer migration is
authorized.

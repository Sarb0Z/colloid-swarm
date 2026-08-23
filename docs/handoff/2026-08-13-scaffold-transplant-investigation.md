# Scaffold transplant investigation

## The question

Can the current colloid-swarm scaffold be transplanted onto Mailstation,
writing-coach, MillCRM, ClearClaim, and RaviTravels without overwriting target
work or changing user-wide Codex trust settings?

## Findings

- The canonical export completed from `HEAD` into an isolated kit. It dropped
  16 Colloid-only paths, stripped marked regions from 16 files, and generated
  four debt-log seed entries.
- The five targets were located at:
  `Mailstation/mailstation`, `writing-coach`, `FlourCRM/millcrm`,
  `Incura/clearclaim`, and `RaviTravels/ravi-travels`.
- Existing dirty product/operator files were inventoried and preserved. The
  transplant was not committed and Codex trust activation was not run.
- Shared scaffold runtime files were merged into all five repositories. The
  generated debt entries were appended only where absent.
- Stack-specific additions were made for Rails in MillCRM, Next.js in
  ClearClaim, and Next.js plus Expo in RaviTravels. Missing `qa-verifier` was
  added to Mailstation. MillCRM received the repository-owned research and
  security MCP bundles because it had no project MCP registry.
- Layout verification passed for Mailstation (59 links), writing-coach (65),
  ClearClaim (64), and RaviTravels (69). MillCRM's real pre-existing host
  integration is incompatible with the canonical symlink contract, so its
  layout check remains blocked without replacing target-local host files.
- Skill and stack checks passed for Mailstation (12 skills), writing-coach (14),
  ClearClaim (13), and RaviTravels (14; two stack packs). MillCRM's existing 26
  target-local skills lack required `AGENTS.md` files and several reference
  files lack contents tables; those files were intentionally not rewritten.
- Session-start verification passed for Mailstation. Its MCP registry was
  replaced with the canonical schema; MCP registry tests and Codex host-loader
  integration checks now pass.

## Ruled out

- Blind `rsync --delete` was not used. It would risk deleting target-local
  skills, debt, memory, and operator state.
- Canonical MCP reset was not applied. Existing target registries and their
  arguments were preserved.
- `trust-hooks.py` was not run. The repository exposes the trust tooling, but
  user-wide Codex trust choices were left unchanged.
- MillCRM's existing `.claude`, `.codex`, `.github`, and legacy Rails skill
  library were not replaced merely to make the canonical layout check green.

## Open questions, risks, and next step

1. MillCRM needs a separate host-integration migration if its real files are to
   become canonical symlinks. Its legacy skill library also needs a bounded
   governance migration before the canonical skill lint can pass.
2. The target repositories contain uncommitted transplant diffs by design.
   Review and commit each target separately after the two decisions above.

Recommended next step: review and commit each target separately, leaving
MillCRM as an explicitly partial transplant until its host-layer migration is
authorized.

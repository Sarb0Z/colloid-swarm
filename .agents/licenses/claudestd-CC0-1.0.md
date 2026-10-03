# claudestd

`.agents/rules/stack-typescript.md`, `stack-python.md` and `stack-rust.md` adapt
the language files of https://github.com/zorbathut/claudestd (branch `dev`,
commit `cc3e323214030445219a54c3aac01a08128bdc2e`) by zorbathut. The source is
dedicated to the public domain under CC0 1.0
(https://creativecommons.org/publicdomain/zero/1.0/), so no notice is required.
This file records the provenance.

Root `AGENTS.md` adapts two sections of `CLAUDE-general.md` from the same commit, "Errors fail loudly" and "Commits split along seams". They differ from the source in these ways:

- They limit the error rule to code that the agent writes or changes, and let a hook that must not block exit 0.
- They say "validate at each system boundary, on the side that enforces it" where the source says "only validate at system boundaries".
- They narrow late fixes to review fixes, and allow a fold only into an unpushed and unintegrated commit in an unshared tree.
- They drop the source's "never commit unless told" gate. When to commit is set elsewhere.
- They hold "tests go in the commit that makes them meaningful" for the testing write-up.

The language packs have these differences from the source:

- It omits these rules:
  - the rules that depend on the source's `CLAUDE-general.md`;
  - its category-first naming convention;
  - its line-width and comment-wrapping rules;
  - its naming conventions per language;
  - its "no decorators, no DI containers" rule;
  - every style rule that a formatter or a linter can apply (braces, function
    form, exports, `const` and `var`, file names, import prefixes). The root
    `AGENTS.md` puts those in tooling.
- It forbids `@ts-expect-error`, because the root `AGENTS.md` bans suppression
  comments.
- It limits every rule to code that the agent writes or changes. The source
  targets new projects.
- It lets framework packs win wherever they conflict.
- It holds the source's testing rules for the testing write-up
  (`docs/handoff/2026-10-03-testing-writeup-inputs.md`) instead of the packs.

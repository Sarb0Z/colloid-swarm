# claudestd

`.agents/rules/stack-typescript.md`, `stack-python.md` and `stack-rust.md` adapt
the language files of https://github.com/zorbathut/claudestd (branch `dev`,
commit `cc3e323214030445219a54c3aac01a08128bdc2e`) by zorbathut. The source is
dedicated to the public domain under CC0 1.0
(https://creativecommons.org/publicdomain/zero/1.0/), so no notice is required.
This file records the provenance.

The adaptation has these differences from the source:

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
- It makes pytest a convention where the project has it, not a mandate.

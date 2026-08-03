---
applyTo: '.agents/skills/react-native-expert/**,.claude/skills/react-native-expert/**'
paths:
  - '.agents/skills/react-native-expert/**'
  - '.claude/skills/react-native-expert/**'
---

# React-Native-Expert Skill Rules

## Business Invariants
- The library defaults must stay current. This skill teaches `expo-image` over the deprecated `react-native-fast-image`, and LegendList/FlashList over `FlatList`. When a recommended library deprecates, update the default — a stale default is worse than none.
- The `{falsy && <JSX>}` crash rule is load-bearing, not style advice: `count && ...` renders a bare `0` outside `<Text>` and hard-crashes in production. Do not soften it to a lint-preference.
- `SKILL.md` keeps the reference table, project structure, the rendering-safety rules, and the quick reference. Everything else lives in a sibling reference file, one level deep, read on demand at no context cost until opened. The body stays under the documented 500-line guidance.
- One topic per reference file, and one reference-table row per file. Bundling two unrelated topics to pad a file makes an agent load both to reach either.
- The `description` carries the trigger terms, because `name` and `description` are the metadata that drives skill selection. `autoInvoke`, `priority`, and `triggers:` are not supported keys in any engine spec, and nothing in this repo reads them; do not add them.
- `allowed-tools` is not set, and must not be. It pre-approves the listed tools for the invoking turn — a documentation skill that grants itself `Edit` and `Write` suppresses a permission prompt it has no need to suppress.
- The body must not prescribe a structure a reference file contradicts. `SKILL.md` teaches the module layout because it is always loaded; a corrective that only arrives on an optional read arrives too late.

## Abnormal Cases and Rationale
- Rendering safety stays inline in `SKILL.md` rather than moving to a reference file. It is the one section whose omission crashes production, and a reference file is only read when the agent decides it is relevant — which is exactly the judgement that fails here.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.

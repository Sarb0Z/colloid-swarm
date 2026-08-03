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

- `SKILL.md` keeps only navigation, auto-detection, project structure, the rendering-safety rules, and the quick reference. Everything else lives in a sibling reference file, one level deep. The body is held under the documented 500-line guidance; it was 918 once, and reference files are read on demand at no context cost until opened.
- The `description` carries the trigger terms. `autoInvoke`, `priority`, and a `triggers:` array were removed: no engine spec defines them, no hook or script in this repo reads them, and no sibling skill uses them. The `name` and `description` metadata are what actually drive skill selection, so the terms live there. Do not re-add the keys.

## Abnormal Cases and Rationale
- Rendering safety stays inline in `SKILL.md` rather than moving to a reference file. It is the one section whose omission crashes production, and a reference file is only read when the agent decides it is relevant — which is exactly the judgement that fails here.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.

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

## Abnormal Cases and Rationale
- None recorded yet.

## Out of Scope
- Do not restate `SKILL.md` usage instructions. This file governs edits to the skill.

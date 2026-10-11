---
applyTo: '**/app/**/*.tsx,**/src/app/**/*.tsx,**/app.config.*,**/eas.json,**/metro.config.*'
paths:
  - '**/app/**/*.tsx'
  - '**/src/app/**/*.tsx'
  - '**/app.config.*'
  - '**/eas.json'
  - '**/metro.config.*'
detect:
  - '**/app.json'
  - '**/app.config.*'
  - '**/eas.json'
---

# Expo and React Native Rules

## Business Invariants
- Only `EXPO_PUBLIC_`-prefixed variables reach the client bundle, and everything that reaches it is readable by any user of the build. Never give that prefix to a credential. Hold a secret with `eas env:set --visibility secret` and read it on a server the app calls.
- A route is a file under `app/`. `+not-found.tsx`, `+html.tsx`, and `+native-intent.tsx` are Expo Router's reserved names — a screen must not take a `+` prefix.
- A long list uses `FlashList`, never `ScrollView` with a `map`. A `ScrollView` mounts every row at once and the cost is linear in the data.
- Every list row carries a stable `keyExtractor` and a memoized `renderItem`. An inline arrow rebuilds the row on each parent render and defeats the virtualization.
- Animation runs on the UI thread through Reanimated worklets. An animation driven from React state re-renders per frame on the JS thread and drops frames under load.
- A native dependency changes the build, not the bundle. Adding one requires a new development build; it cannot arrive over an update channel.

## Abnormal Cases and Rationale
- The two platforms diverge in ways the type system does not carry: safe-area insets, keyboard avoidance, back-gesture handling, and shadow rendering. Test a screen on both before you call it done.
- A component that reads `Dimensions` once holds a stale size after rotation or a foldable unfolds. Read the value through a hook that subscribes.

## Out of Scope
- Do not restate visual design rules here. `.agents/rules/frontend.md` owns those.

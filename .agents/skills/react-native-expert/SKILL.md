---
name: react-native-expert
description: "React Native and Expo engineering patterns: modular-monolith architecture, rendering safety, component and list performance, navigation, platform-specific code, image handling, native UI primitives, animations with Reanimated, React Compiler compatibility, state, fonts, monorepos, storage, and testing. Use when building or reviewing React Native or Expo code, when a mobile screen crashes on render or drops frames in a long list, when navigation or deep linking needs wiring, when platform behavior diverges between iOS and Android, when a component must be made compiler-safe, or when an Expo native dependency needs monorepo or build configuration. Trigger terms: react-native, react native, expo, mobile, iOS, Android, NativeWind, Reanimated, FlatList, FlashList, React Navigation, safe area, native module, Expo fonts, monorepo."
---

# React Native expert

React Native and Expo patterns: rendering safety, module layout, performance, navigation, and platform divergence. The two rendering-safety rules lead, and stay in this file, because their omission crashes production and a reference file is read only when the agent judges it relevant — the very judgement that fails on a line that looks harmless.

## Rendering safety

### Render text only inside `<Text>`

Every string and text node must be a descendant of `<Text>`. React Native does not permit bare text inside `<View>`, `<Pressable>`, or any other non-text component; see the [React Native Text documentation](https://reactnative.dev/docs/text).

```tsx
// ❌ BAD - a text node is a direct child of View
<View>Hello</View>

// ✅ GOOD
<View><Text>Hello</Text></View>
```

### Never `&&` with a potentially falsy value

Never write `{value && <Component />}` when `value` could be `0` or an empty string. Both are falsy yet **JSX-renderable**: React Native tries to render the bare `0` or `""` outside a `<Text>`, and the result is a **hard crash in production** — one of the commonest React Native production crashes. The pattern reads as idiomatic React, and on the web a stray `0` is only a visible glitch; on a device it passes every render with a non-zero count and waits for the first empty list.

```tsx
// ❌ BAD - `count && ...` renders a bare `0` when count is 0 → hard crash.
// (`name && ...` with name === "" renders nothing rather than crashing, but is
// still a leak-prone smell — coerce it too.)
function Profile({ name, count }: { name: string; count: number }) {
  return (
    <View>
      {name && <Text>{name}</Text>}
      {count && <Text>{count} items</Text>}
    </View>
  );
}
// count === 0 renders a bare `0` outside <Text> → crash

// ✅ GOOD - ternary with null
function Profile({ name, count }: { name: string; count: number }) {
  return (
    <View>
      {name ? <Text>{name}</Text> : null}
      {count ? <Text>{count} items</Text> : null}
    </View>
  );
}

// ✅ GOOD - explicit boolean coercion
{!!name && <Text>{name}</Text>}
{!!count && <Text>{count} items</Text>}

// ✅ BEST - early return, then unconditional render
function Profile({ name, count }: { name: string; count: number }) {
  if (!name) return null;
  return (
    <View>
      <Text>{name}</Text>
      {count > 0 ? <Text>{count} items</Text> : null}
    </View>
  );
}
```

**Lint rule:** enable `react/jsx-no-leaked-render` from `eslint-plugin-react`, which catches this automatically. A reviewer has to remember the rule on every diff; the lint error does not forget.

## Project structure

Organize by **feature module**, not by technical layer. A tree of `components/`, `screens/`, and `services/` couples every feature to every other and leaves none of them deletable. A feature that cannot be deleted is one every other feature has quietly come to depend on.

```
src/
├── app/                  # Routes and composition only
├── modules/              # Self-contained feature modules
│   └── <feature>/        # Owns its screens, components, hooks,
│                         # services, types, stores, validations
└── shared/               # Primitives used by 2+ modules
```

A module must be deletable without breaking unrelated features, and must not import from another module: promote the shared code to `src/shared/` on its second consumer, not its first, since a promotion made for one caller guesses at a reuse that may never arrive. Module boundaries, the promotion rule, and the dependency direction are in [architecture.md](architecture.md).

Below a handful of screens a flat layer tree is not yet wrong; the module split is what carries an app past that point, so start there rather than migrating later.

## Reference

Read the file for the area in hand. Each holds one topic and stands alone, so reaching one never costs loading another.

| Area | File |
|---|---|
| Module boundaries, dependency rules, promotion to `shared/` | [architecture.md](architecture.md) |
| Component patterns, list performance, native UI primitives | [components-and-lists.md](components-and-lists.md) |
| React Navigation, deep linking | [navigation.md](navigation.md) |
| `Platform.select`, safe area, platform divergence | [platform.md](platform.md) |
| `expo-image`, galleries, caching | [images.md](images.md) |
| Reanimated, React Compiler compatibility | [animations.md](animations.md) |
| Derived state, functional updates, local overrides | [state.md](state.md) |
| Expo font integration | [fonts.md](fonts.md) |
| Expo workspaces, native dependency alignment | [monorepos.md](monorepos.md) |
| SecureStore, AsyncStorage, persistence | [storage.md](storage.md) |
| React Native Testing Library | [testing.md](testing.md) |

## Quick reference

```toon
checklist[20]{area,best_practice}:
  Text,Render strings and text nodes only inside <Text>
  Rendering,Never {falsy && <JSX>} — use ternary or !! (0/"" crashes)
  Lists,Default to LegendList or FlashList over FlatList
  Images,expo-image (react-native-fast-image is deprecated)
  Galleries,Galeria for lightbox and pinch-to-zoom
  Menus,Zeego native dropdown and context menus
  Modals,Native Modal formSheet over JS bottom sheets
  Navigation,Type-safe with RootStackParamList
  Architecture,Modular monolith — deletable src/modules/<feature>
  Routing,src/app is routes and composition only
  Logic,Business logic in hooks screens stay presentational
  Styling,Detect project approach (NativeWind/StyleSheet)
  Platform,Use Platform.select for differences
  Animations,GestureDetector Gesture.Tap for press states
  React Compiler,Use Reanimated 4 get/set only with Compiler and New Architecture
  State,Derive presentation values and use functional setters for dependent updates
  Fonts,Use the Expo font config plugin for native builds
  Monorepos,Declare imports per workspace and deduplicate native modules
  Storage,SecureStore for tokens AsyncStorage for prefs
  Testing,React Native Testing Library
```

Source provenance is in [UPSTREAM.json](UPSTREAM.json).

---
name: react-native-expert
description: "React Native and Expo engineering patterns: modular-monolith architecture, rendering safety, component and list performance, navigation, platform-specific code, image handling, native UI primitives, animations with Reanimated, React Compiler compatibility, storage, and testing. Use when building or reviewing React Native or Expo code, when a mobile screen crashes on render or drops frames in a long list, when navigation or deep linking needs wiring, when platform behaviour diverges between iOS and Android, or when a component must be made compiler-safe. Trigger terms: react-native, react native, expo, mobile, iOS, Android, NativeWind, Reanimated, FlatList, FlashList, React Navigation, safe area, native module."
allowed-tools: Read, Grep, Glob, Edit, Write
---

# React Native Expert Skill

Expert-level React Native patterns, mobile-specific optimizations, navigation, and platform handling.

---

## Auto-Detection

This skill activates when:
- Working with React Native projects
- Detected `react-native` or `expo` in package.json
- Building mobile components
- Platform-specific code needed

---

## 1. Project Structure

### Recommended Structure

```
src/
├── components/           # Shared components
│   ├── ui/              # Base UI components
│   └── common/          # Business components
├── screens/             # Screen components
├── navigation/          # Navigation config
├── hooks/               # Custom hooks
├── services/            # API services
├── stores/              # State management
├── utils/               # Utilities
├── constants/           # App constants
├── types/               # TypeScript types
└── assets/              # Images, fonts
```

---

## 3. Rendering Safety (CRITICAL)

### Never use `&&` with potentially-falsy values

Never write `{value && <Component />}` when `value` could be `0` or an empty
string. Those are falsy but **JSX-renderable** — React Native tries to render the
bare `0` or `""` outside a `<Text>`, causing a **hard crash in production**. This
is one of the most common React Native production crashes.

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

**Lint rule:** enable `react/jsx-no-leaked-render` from `eslint-plugin-react` to
catch this automatically.

---

## Reference

Read the file for the area in hand; each is self-contained.

| Area | File |
|---|---|
| Modular-monolith layering, module boundaries, dependency rules | [architecture.md](architecture.md) |
| Component patterns, list performance, native UI primitives | [components-and-lists.md](components-and-lists.md) |
| React Navigation, deep linking | [navigation.md](navigation.md) |
| Platform-specific code, image handling | [platform-and-images.md](platform-and-images.md) |
| Reanimated, React Compiler compatibility | [animations.md](animations.md) |
| Storage, persistence, testing | [storage-and-testing.md](storage-and-testing.md) |

---

## Quick Reference

```toon
checklist[16]{area,best_practice}:
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
  React Compiler,Destructure hook fns; shared values via get/set
  Storage,SecureStore for tokens AsyncStorage for prefs
  Testing,React Native Testing Library
```

---

**Version:** 1.4.0

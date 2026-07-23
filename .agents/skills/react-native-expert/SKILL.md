---
name: react-native-expert
description: "React Native best practices expert. PROACTIVELY use when working with React Native, mobile apps, Expo. Triggers: react-native, expo, mobile, iOS, Android, NativeWind"
autoInvoke: true
priority: high
triggers:
  - "react-native"
  - "react native"
  - "expo"
  - "mobile"
  - "nativewind"
  - "iOS"
  - "Android"
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

## 2. Architecture: Modular Monolith

As an app grows past a handful of screens, organize by **feature module**, not by
technical layer. Two top-level concerns live under `src/`:

- **`src/modules/<feature>/`** — self-contained feature modules. Each module owns
  its screens, components, hooks, services, types, stores, and validations. A
  module must be **deletable** without breaking unrelated features.
- **`src/shared/`** — cross-module primitives (UI building blocks, utilities,
  hooks) used by **two or more** modules.

### A module must not import from another module

If two modules need the same thing, promote it to `src/shared/`.

```
// ❌ BAD - groceries silently depends on recipes
src/modules/recipes/components/RecipeCard.tsx
src/modules/groceries/screens/GroceryList.tsx
  └── import RecipeCard from '@/modules/recipes/components/RecipeCard'
// Deleting or refactoring recipes now breaks groceries

// ✅ GOOD - promote the shared primitive, both import from src/shared
src/shared/ui/recipe-card/RecipeCard.tsx
src/modules/recipes/screens/RecipeList.tsx
  └── import { RecipeCard } from '@/shared/ui/recipe-card'
src/modules/groceries/screens/GroceryList.tsx
  └── import { RecipeCard } from '@/shared/ui/recipe-card'
```

### Promote on the second consumer

- Used by 1 module → keep it **inside** that module.
- Used by 2+ modules → move to `src/shared/`.
- Don't pre-promote. Move things when the second consumer appears, not before —
  premature sharing creates coupling and an unclear ownership story.
- If a "shared" file ends up used by only one module after a refactor, demote it
  back into that module.

### Module layout

```
src/modules/recipes/
  screens/        ← presentational, mounted by src/app/ routes
  components/     ← module-local UI
  hooks/          ← business logic
  services/       ← API calls
  stores/         ← module-local state
  types/
  index.ts        ← public surface of the module (keep it small)
```

Only what a module exports from `index.ts` is its public API.

### Keep the routing layer as routes and composition only

If using Expo Router, `src/app/` is the **routing/composition** layer — route
files, `_layout.tsx` shells, and screen wiring only. It must not contain feature
UI, business logic, state, or data fetching.

```tsx
// ❌ BAD - src/app/(tabs)/recipes/index.tsx owns the whole feature
export default function RecipesScreen() {
  const [search, setSearch] = useState('');
  const query = useRecipeSearch(search);
  const allRecipes = useMemo(
    () => query.data?.pages.flatMap(p => p.recipes) ?? [],
    [query.data],
  );
  // …200 lines of UI, hooks, handlers, JSX…
  return <View>…</View>;
}
// Can't be reused, can't be tested without the router, unmaintainable

// ✅ GOOD - route file composes a module screen
// src/app/(tabs)/recipes/index.tsx
import { RecipesScreen } from '@/modules/recipes';

export default function RecipesRoute() {
  return <RecipesScreen />;
}
```

Most route files end up as a single-line render of a module screen, with maybe a
`<Stack.Screen options={…} />` for header config.

### Business logic in hooks, UI in screens

Screens are **presentational** — they assemble UI and bind values/handlers from
hooks. All business logic (fetching, derivations, mutations, validation,
navigation decisions, side effects) belongs in a `use<Screen>` hook co-located
with the screen. This keeps screens readable as JSX and lets logic be tested
without mounting a render tree.

```tsx
// ✅ GOOD - hook owns the logic
// src/modules/recipes/hooks/useRecipesScreen.ts
export function useRecipesScreen() {
  const router = useRouter();
  const [search, setSearch] = useState('');
  const debouncedSetSearch = useDebouncedCallback(setSearch, 500);
  const query = useRecipeSearch(search);

  const recipes = useMemo(
    () => query.data?.pages.flatMap(p => p.recipes) ?? [],
    [query.data],
  );

  const onEndReached = useCallback(() => {
    if (query.hasNextPage && !query.isFetchingNextPage) query.fetchNextPage();
  }, [query]);

  const onRecipePress = useCallback(
    (recipe: RecipeDetail) => router.push(`/recipe/${recipe.id}`),
    [router],
  );

  return { recipes, query, debouncedSetSearch, onEndReached, onRecipePress };
}

// src/modules/recipes/screens/RecipesScreen.tsx - mostly JSX
export function RecipesScreen() {
  const { recipes, query, debouncedSetSearch, onEndReached, onRecipePress } =
    useRecipesScreen();

  return (
    <View>
      <SearchBar onChange={debouncedSetSearch} />
      <LegendList
        data={recipes}
        renderItem={({ item }) => (
          <RecipeCard {...item} onPress={() => onRecipePress(item)} />
        )}
        onEndReached={onEndReached}
        estimatedItemSize={120}
      />
    </View>
  );
}
```

Heuristic: if you reach for `useState`/`useMemo`/`useEffect`/`useCallback`,
mutations, or query hooks alongside a large render tree in the same file — extract
a `use<Screen>` hook.

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

## 4. Component Patterns

### Adaptive Styling Detection

```typescript
// ✅ GOOD - Detect and use project's styling approach
// Check package.json for: nativewind, emotion, styled-components, or use StyleSheet

// NativeWind (Tailwind)
import { styled } from 'nativewind';
const StyledView = styled(View);
<StyledView className="flex-1 bg-white p-4" />

// StyleSheet (default)
const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: 'white', padding: 16 },
});
<View style={styles.container} />

// Emotion
import styled from '@emotion/native';
const Container = styled.View`flex: 1; background-color: white;`;
```

### Performance-Optimized Components

```tsx
// ✅ GOOD - Memoized list item
const ListItem = React.memo(function ListItem({ item, onPress }: Props) {
  const handlePress = useCallback(() => {
    onPress(item.id);
  }, [item.id, onPress]);

  return (
    <Pressable onPress={handlePress}>
      <Text>{item.title}</Text>
    </Pressable>
  );
});
```

### Pressable, never Touchable

Never use `TouchableOpacity` or `TouchableHighlight` — use `Pressable`. Inside
scrollable lists, use `Pressable` from `react-native-gesture-handler` for better
gesture coordination (as long as the list's ScrollView is also from gesture
handler).

```tsx
// ❌ BAD - legacy Touchable
import { TouchableOpacity } from 'react-native';
<TouchableOpacity onPress={onPress} activeOpacity={0.7}>
  <Text>Press me</Text>
</TouchableOpacity>

// ✅ GOOD - Pressable
import { Pressable } from 'react-native';
<Pressable
  onPress={handlePress}
  style={({ pressed }) => [styles.button, pressed && styles.buttonPressed]}
  android_ripple={{ color: 'rgba(0,0,0,0.1)' }}
>
  <Text>Press Me</Text>
</Pressable>
```

For **animated** press states (scale/opacity on press), reach for
`GestureDetector` with `Gesture.Tap()` instead — see section 10.

---

## 5. Lists

### Default to a virtualizer — even for short lists

Prefer **LegendList** or **FlashList** over `FlatList`, and never render a list by
mapping children inside a `ScrollView`. Virtualizers mount only visible items,
cutting memory and mount time. A `ScrollView` with mapped children mounts
everything upfront and gets expensive fast.

```tsx
// ❌ BAD - ScrollView mounts all 50 items even if 10 are visible
<ScrollView>
  {items.map((item) => <ItemCard key={item.id} item={item} />)}
</ScrollView>

// ✅ GOOD - LegendList (drop-in, best defaults today)
import { LegendList } from '@legendapp/list';

<LegendList
  data={items}
  // Wrap renderItem/keyExtractor in useCallback unless React Compiler is on
  renderItem={({ item }) => <ItemCard item={item} />}
  keyExtractor={(item) => item.id}
  estimatedItemSize={80}
/>

// ✅ GOOD - FlashList alternative
import { FlashList } from '@shopify/flash-list';

<FlashList
  data={items}
  renderItem={({ item }) => <ItemCard item={item} />}
  keyExtractor={(item) => item.id}
/>
```

### Tuning an existing FlatList

New lists should use LegendList/FlashList. When maintaining an existing
`FlatList`, these props matter:

```tsx
// ✅ GOOD - stable, memoized callbacks are non-negotiable
const renderItem = useCallback(({ item }: { item: Item }) => (
  <ListItem item={item} onPress={handlePress} />
), [handlePress]);

const keyExtractor = useCallback((item: Item) => item.id, []);

// getItemLayout only when every row is a fixed height
const getItemLayout = useCallback((_data, index: number) => ({
  length: ITEM_HEIGHT,
  offset: ITEM_HEIGHT * index,
  index,
}), []);

<FlatList
  data={items}
  renderItem={renderItem}
  keyExtractor={keyExtractor}
  getItemLayout={getItemLayout}
  removeClippedSubviews
  maxToRenderPerBatch={10}
  windowSize={5}
  initialNumToRender={10}
  extraData={selectedId}   // so selection changes actually re-render rows
/>
```

---

## 6. Navigation (React Navigation)

### Type-Safe Navigation

```tsx
// ✅ GOOD - Define navigation types
type RootStackParamList = {
  Home: undefined;
  Profile: { userId: string };
  Settings: { section?: string };
};

type ProfileScreenProps = NativeStackScreenProps<RootStackParamList, 'Profile'>;

// ✅ GOOD - Type-safe navigation hook
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';

type NavigationProp = NativeStackNavigationProp<RootStackParamList>;

function MyComponent() {
  const navigation = useNavigation<NavigationProp>();

  const goToProfile = (userId: string) => {
    navigation.navigate('Profile', { userId });
  };
}
```

### Deep Linking

```tsx
// ✅ GOOD - Configure deep linking
const linking = {
  prefixes: ['myapp://', 'https://myapp.com'],
  config: {
    screens: {
      Home: '',
      Profile: 'user/:userId',
      Settings: 'settings',
    },
  },
};

<NavigationContainer linking={linking}>
  {/* ... */}
</NavigationContainer>
```

---

## 7. Platform-Specific Code

### Platform Selection

```tsx
import { Platform, StyleSheet } from 'react-native';

// ✅ GOOD - Platform.select
const styles = StyleSheet.create({
  shadow: Platform.select({
    ios: {
      shadowColor: '#000',
      shadowOffset: { width: 0, height: 2 },
      shadowOpacity: 0.25,
      shadowRadius: 3.84,
    },
    android: {
      elevation: 5,
    },
    default: {},
  }),
});

// ✅ GOOD - Platform-specific files
// Button.ios.tsx
// Button.android.tsx
// Button.tsx (fallback)
import Button from './Button'; // Auto-selects platform
```

### Safe Area Handling

```tsx
import { SafeAreaView, useSafeAreaInsets } from 'react-native-safe-area-context';

// ✅ GOOD - SafeAreaView for screens
function Screen() {
  return (
    <SafeAreaView style={{ flex: 1 }} edges={['top', 'bottom']}>
      <Content />
    </SafeAreaView>
  );
}

// ✅ GOOD - useSafeAreaInsets for custom handling
function CustomHeader() {
  const insets = useSafeAreaInsets();
  return (
    <View style={{ paddingTop: insets.top }}>
      <HeaderContent />
    </View>
  );
}
```

---

## 8. Image Handling

### Use expo-image

Use `expo-image`, not React Native's `Image`. It gives memory-efficient caching,
blurhash placeholders, progressive loading, and better list performance.

> `react-native-fast-image` is **deprecated and unmaintained** — do not reach for
> it in new code. `expo-image` supersedes it.

```tsx
// ❌ BAD - deprecated
import FastImage from 'react-native-fast-image';

// ✅ GOOD - expo-image (same JSX shape as RN Image)
import { Image } from 'expo-image';

function Avatar({ url }: { url: string }) {
  return <Image source={{ uri: url }} style={styles.avatar} />;
}

// ✅ GOOD - blurhash placeholder + fade-in
<Image
  source={{ uri: url }}
  placeholder={{ blurhash: 'LGF5]+Yk^6#M@-5c,1J5@[or[Q6.' }}
  contentFit="cover"
  transition={200}
  style={styles.image}
/>

// ✅ GOOD - priority + caching for a hero image
<Image
  source={{ uri: url }}
  priority="high"
  cachePolicy="memory-disk"
  style={styles.hero}
/>
```

Key props: `placeholder` (blurhash/thumb), `contentFit`
(`cover`/`contain`/`fill`/`scale-down`), `transition` (ms), `priority`
(`low`/`normal`/`high`), `cachePolicy`
(`memory`/`disk`/`memory-disk`/`none`), `recyclingKey` (for list recycling).

### Galleries and lightbox: Galeria

For tap-to-fullscreen galleries, use `@nandorojo/galeria` instead of a hand-rolled
`Modal`. It gives native shared-element transitions, pinch-to-zoom, double-tap
zoom, and pan-to-close, and works with any image component.

```tsx
// ✅ GOOD - Galeria with expo-image
import { Galeria } from '@nandorojo/galeria';
import { Image } from 'expo-image';

function ImageGallery({ urls }: { urls: string[] }) {
  return (
    <Galeria urls={urls}>
      {urls.map((url, index) => (
        <Galeria.Image index={index} key={url}>
          <Image source={{ uri: url }} style={styles.thumbnail} />
        </Galeria.Image>
      ))}
    </Galeria>
  );
}
```

---

## 9. Native UI Primitives

Rely on native UI for low-level primitives — you get accessibility, platform-
consistent UX, and performance for free.

### Menus and context menus: Zeego

Use [zeego](https://zeego.dev) for cross-platform native dropdown and context
menus instead of a custom absolutely-positioned JS menu.

```tsx
// ❌ BAD - custom JS menu, no accessibility, wrong platform feel
{open && (
  <View style={{ position: 'absolute', top: 40 }}>
    <Pressable onPress={onEdit}><Text>Edit</Text></Pressable>
    <Pressable onPress={onDelete}><Text>Delete</Text></Pressable>
  </View>
)}

// ✅ GOOD - native menu via zeego
import * as DropdownMenu from 'zeego/dropdown-menu';

function RowMenu() {
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger>
        <Pressable><Text>Open Menu</Text></Pressable>
      </DropdownMenu.Trigger>
      <DropdownMenu.Content>
        <DropdownMenu.Item key="edit" onSelect={onEdit}>
          <DropdownMenu.ItemTitle>Edit</DropdownMenu.ItemTitle>
        </DropdownMenu.Item>
        <DropdownMenu.Item key="delete" destructive onSelect={onDelete}>
          <DropdownMenu.ItemTitle>Delete</DropdownMenu.ItemTitle>
        </DropdownMenu.Item>
      </DropdownMenu.Content>
    </DropdownMenu.Root>
  );
}
```

Zeego also covers long-press context menus (`zeego/context-menu`), checkbox
items, and submenus with the same component shape.

### Modals and bottom sheets: prefer native

Use the native `<Modal>` with `presentationStyle="formSheet"` (or React
Navigation v7's native form sheet) instead of a JS-based bottom-sheet library.
Native modals bring swipe-to-dismiss, keyboard avoidance, and accessibility out
of the box.

```tsx
// ✅ GOOD - native form sheet
import { Modal, View, Text, Button } from 'react-native';

function MyScreen() {
  const [visible, setVisible] = useState(false);
  return (
    <View style={{ flex: 1 }}>
      <Button onPress={() => setVisible(true)} title="Open" />
      <Modal
        visible={visible}
        presentationStyle="formSheet"
        animationType="slide"
        onRequestClose={() => setVisible(false)}
      >
        <View><Text>Sheet content</Text></View>
      </Modal>
    </View>
  );
}

// ✅ GOOD - React Navigation v7 native form sheet
<Stack.Screen
  name="Details"
  component={DetailsScreen}
  options={{ presentation: 'formSheet', sheetAllowedDetents: 'fitToContents' }}
/>
```

---

## 10. Animations

### Reanimated Best Practices

```tsx
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withSpring,
  withTiming,
  runOnJS,
} from 'react-native-reanimated';

// ✅ GOOD - Worklet-based animations
function AnimatedCard() {
  const scale = useSharedValue(1);

  const animatedStyle = useAnimatedStyle(() => ({
    transform: [{ scale: scale.value }],
  }));

  const handlePressIn = () => {
    scale.value = withSpring(0.95);
  };

  const handlePressOut = () => {
    scale.value = withSpring(1);
  };

  return (
    <Pressable onPressIn={handlePressIn} onPressOut={handlePressOut}>
      <Animated.View style={[styles.card, animatedStyle]}>
        <Content />
      </Animated.View>
    </Pressable>
  );
}
```

### Gesture Handler

```tsx
import { Gesture, GestureDetector } from 'react-native-gesture-handler';

// ✅ GOOD - Gesture-based interactions
function SwipeableCard() {
  const translateX = useSharedValue(0);

  const gesture = Gesture.Pan()
    .onUpdate((e) => {
      translateX.value = e.translationX;
    })
    .onEnd(() => {
      translateX.value = withSpring(0);
    });

  const animatedStyle = useAnimatedStyle(() => ({
    transform: [{ translateX: translateX.value }],
  }));

  return (
    <GestureDetector gesture={gesture}>
      <Animated.View style={animatedStyle}>
        <Card />
      </Animated.View>
    </GestureDetector>
  );
}
```

### Animated press states: GestureDetector, not Pressable callbacks

For scale/opacity-on-press feedback, drive the animation from `Gesture.Tap()`
rather than Pressable's `onPressIn`/`onPressOut`. Gesture callbacks run on the UI
thread as worklets — no JS-thread round-trip, so the feedback stays smooth under
load. Store the press **state** (0/1) as the shared value and derive the visual
via `interpolate`.

```tsx
// ❌ BAD - press animation bounces through the JS thread
<Pressable
  onPress={onPress}
  onPressIn={() => (scale.value = withTiming(0.95))}
  onPressOut={() => (scale.value = withTiming(1))}
>
  <Animated.View style={animatedStyle}>
    <Text>Press me</Text>
  </Animated.View>
</Pressable>

// ✅ GOOD - Gesture.Tap on the UI thread
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, {
  useSharedValue, useAnimatedStyle, withTiming, interpolate, runOnJS,
} from 'react-native-reanimated';

function AnimatedButton({ onPress }: { onPress: () => void }) {
  const pressed = useSharedValue(0); // 0 = up, 1 = down

  const tap = Gesture.Tap()
    .onBegin(() => pressed.set(withTiming(1)))
    .onFinalize(() => pressed.set(withTiming(0)))
    .onEnd(() => runOnJS(onPress)());

  const animatedStyle = useAnimatedStyle(() => ({
    // `pressed` is already animated via withTiming in the gesture callbacks;
    // interpolate its current value directly — never wrap .get() in withTiming
    // inside useAnimatedStyle (it re-runs every frame → double animation).
    transform: [{ scale: interpolate(pressed.get(), [0, 1], [1, 0.95]) }],
  }));

  return (
    <GestureDetector gesture={tap}>
      <Animated.View style={animatedStyle}>
        <Text>Press me</Text>
      </Animated.View>
    </GestureDetector>
  );
}
```

---

## 11. React Compiler Compatibility

If the project has **React Compiler** enabled, two patterns are required for the
compiler to memoize correctly.

### Destructure functions early in render

Destructure functions from hooks at the top of the render scope. Never dot into
an object to call a function — the compiler keys its cache on the object, which is
a fresh reference every render, so memoization breaks.

```tsx
// ❌ BAD - compiler keys the cache on `props` and `router` (new each render)
import { useRouter } from 'expo-router';

function SaveButton(props) {
  const router = useRouter();
  const handlePress = () => {
    props.onSave();
    router.push('/success'); // unstable reference
  };
  return <Button onPress={handlePress}>Save</Button>;
}

// ✅ GOOD - destructure so the compiler keys on stable references
function SaveButton({ onSave }) {
  const { push } = useRouter();
  const handlePress = () => {
    onSave();
    push('/success');
  };
  return <Button onPress={handlePress}>Save</Button>;
}
```

### Reanimated shared values: use `.get()` / `.set()`, not `.value`

With React Compiler on, read and write shared values through `.get()` and
`.set()`. The compiler can't track `.value` property access, so `.value` opts the
component out of compilation.

```tsx
// ❌ BAD - .value opts out of React Compiler
const count = useSharedValue(0);
const increment = () => { count.value = count.value + 1; };
// title={`Count: ${count.value}`}

// ✅ GOOD - explicit methods stay compiler-compatible
const count = useSharedValue(0);
const increment = () => { count.set(count.get() + 1); };
// title={`Count: ${count.get()}`}
```

---

## 12. Storage & Persistence

```tsx
import AsyncStorage from '@react-native-async-storage/async-storage';
import * as SecureStore from 'expo-secure-store';

// ✅ GOOD - AsyncStorage for non-sensitive data
async function saveSettings(settings: Settings) {
  await AsyncStorage.setItem('settings', JSON.stringify(settings));
}

// ✅ GOOD - SecureStore for sensitive data
async function saveToken(token: string) {
  await SecureStore.setItemAsync('authToken', token);
}

// ✅ GOOD - MMKV for performance-critical storage
import { MMKV } from 'react-native-mmkv';

const storage = new MMKV();
storage.set('user.name', 'John');
const name = storage.getString('user.name');
```

---

## 13. Testing

```tsx
import { render, fireEvent, waitFor } from '@testing-library/react-native';

// ✅ GOOD - Component testing
describe('LoginButton', () => {
  it('calls onPress when pressed', () => {
    const onPress = jest.fn();
    const { getByText } = render(<LoginButton onPress={onPress} />);

    fireEvent.press(getByText('Login'));
    expect(onPress).toHaveBeenCalled();
  });
});

// ✅ GOOD - Async testing
it('shows loading then content', async () => {
  const { getByTestId, queryByTestId } = render(<DataScreen />);

  expect(getByTestId('loading')).toBeTruthy();

  await waitFor(() => {
    expect(queryByTestId('loading')).toBeNull();
    expect(getByTestId('content')).toBeTruthy();
  });
});
```

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

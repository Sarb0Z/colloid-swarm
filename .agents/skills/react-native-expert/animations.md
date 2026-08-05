# Animations and React Compiler compatibility

## Contents
- Animations
- Derived values and reactions
- Scroll position
- React Compiler Compatibility

## Animations

### Reanimated Best Practices

For visual-only motion, animate `transform` and `opacity`. These properties do
not require sibling layout to reflow. A transform changes how a view is drawn;
it does not move the layout space that its siblings use. Use a layout animation
when the surrounding layout must also move.

The examples in this section use `.value`. This API works with Reanimated 3 and
with Reanimated 4 when React Compiler is not enabled. See the version-specific
compiler rule below.

```tsx
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withSpring,
  withTiming,
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

## Derived values and reactions

Use `useDerivedValue` for a read-only value that depends on shared values. Use
`useAnimatedReaction` when the operation needs the previous value or must cause
a side effect. The reaction `prepare` function and `react` function must not
read and mutate the same shared value. That cycle can run without end.

See the Reanimated documentation for
[`useDerivedValue`](https://docs.swmansion.com/react-native-reanimated/docs/core/useDerivedValue/)
and
[`useAnimatedReaction`](https://docs.swmansion.com/react-native-reanimated/docs/advanced/useAnimatedReaction/).

```tsx
import { scheduleOnRN } from 'react-native-worklets';
import {
  useAnimatedReaction,
  useDerivedValue,
  useSharedValue,
} from 'react-native-reanimated';

const progress = useSharedValue(0);
const width = useDerivedValue(() => progress.value * MAX_WIDTH);

useAnimatedReaction(
  () => progress.value >= 1,
  (complete, wasComplete) => {
    if (complete && !wasComplete) {
      scheduleOnRN(onComplete);
    }
  },
);
```

## Scroll position

Do not put high-frequency scroll position in React state. Use a shared value
when an animation consumes the position. Use a ref when code only needs to
observe the latest position without a render.

```tsx
const scrollY = useSharedValue(0);
const handler = useAnimatedScrollHandler({
  onScroll: (event) => {
    scrollY.value = event.contentOffset.y;
  },
});

const lastObservedY = useRef(0);
const observeScroll = (event: NativeSyntheticEvent<NativeScrollEvent>) => {
  lastObservedY.current = event.nativeEvent.contentOffset.y;
};
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

The good example below assumes Reanimated 4 with React Compiler. Use `.value`
for the same shared-value operations in Reanimated 3 or without React Compiler.

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
  useSharedValue, useAnimatedStyle, withTiming, interpolate,
} from 'react-native-reanimated';
import { scheduleOnRN } from 'react-native-worklets';

function AnimatedButton({ onPress }: { onPress: () => void }) {
  const pressed = useSharedValue(0); // 0 = up, 1 = down

  const tap = Gesture.Tap()
    .onBegin(() => pressed.set(withTiming(1)))
    .onFinalize(() => pressed.set(withTiming(0)))
    .onEnd(() => scheduleOnRN(onPress));

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

For Reanimated 3, import `runOnJS` from `react-native-reanimated` and call
`runOnJS(onPress)()` instead. Reanimated 4 replaces that API with
[`scheduleOnRN`](https://docs.swmansion.com/react-native-worklets/docs/threading/scheduleOnRN/)
from `react-native-worklets`.

---

## React Compiler Compatibility

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

Use `.get()` and `.set()` only when the project uses Reanimated 4 with React
Compiler. Reanimated 4 requires the New Architecture and the
`react-native-worklets` package. Keep `.value` in Reanimated 3 or in a project
that does not use React Compiler. Check the Reanimated
[migration guide](https://docs.swmansion.com/react-native-reanimated/docs/guides/migration-from-3.x/),
[compatibility table](https://docs.swmansion.com/react-native-reanimated/docs/guides/compatibility/),
and [`useSharedValue`
API](https://docs.swmansion.com/react-native-reanimated/docs/core/useSharedValue/)
before you change this access pattern.

```tsx
// ❌ BAD - property access is not compatible with React Compiler
const count = useSharedValue(0);
const increment = () => { count.value = count.value + 1; };
// title={`Count: ${count.value}`}

// ✅ GOOD - Reanimated 4 with React Compiler
const count = useSharedValue(0);
const increment = () => { count.set(count.get() + 1); };
// title={`Count: ${count.get()}`}
```

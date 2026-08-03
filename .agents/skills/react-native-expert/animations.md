# Animations and React Compiler compatibility

## Contents
- Animations
- React Compiler Compatibility

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

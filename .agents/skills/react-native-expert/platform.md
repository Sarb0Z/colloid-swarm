# Platform-Specific Code

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

On iOS, a scroll view below a native navigation bar may use
`contentInsetAdjustmentBehavior="automatic"` so UIKit adjusts its insets. Use
an explicit `contentInset` only when the iOS layout needs an additional custom
offset. Do not apply these iOS inset rules as a replacement for cross-platform
safe-area handling.

```tsx
// Screen.ios.tsx
<ScrollView
  contentInsetAdjustmentBehavior="automatic"
  contentInset={{ bottom: extraIosBottomInset }}
>
  <Content />
</ScrollView>
```

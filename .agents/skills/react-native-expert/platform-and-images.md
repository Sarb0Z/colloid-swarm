# Platform-specific code and image handling

## Contents
- Platform-Specific Code
- Image Handling

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

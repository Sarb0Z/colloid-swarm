# Navigation

## Navigation (React Navigation)

### Prefer a native stack

Default a new stack to React Navigation
[`native-stack`](https://reactnavigation.org/docs/native-stack-navigator/) or to
the Expo Router `Stack`. These use native platform navigation primitives for
screen transitions and gestures.

Native tabs are a capability choice, not a universal default. Use them only
when the product needs platform-native tab behavior and the installed toolchain
supports the required tab features. Expo Router native tabs use an unstable API
and have documented constraints. Check the current [Expo Router native tabs
documentation](https://docs.expo.dev/router/advanced/native-tabs/) before you
select them. Use JavaScript tabs when the product needs unsupported styling or
behavior.

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

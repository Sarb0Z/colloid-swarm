# Navigation

## Navigation (React Navigation)

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

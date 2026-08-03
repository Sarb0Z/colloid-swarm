# Storage & Persistence

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

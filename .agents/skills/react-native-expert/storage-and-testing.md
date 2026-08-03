# Storage, persistence, and testing

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

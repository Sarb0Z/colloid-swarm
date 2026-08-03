# Testing

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

# Components, lists, and native UI primitives

## Contents
- Component Patterns
- Lists
- Native UI Primitives

## Component Patterns

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

For a repeated row, pass the smallest stable interface that the row needs.
Prefer an item ID and primitive display values when this reduces prop churn.
Define the root action once and let it accept the item ID. Preserve the object
identity of unchanged items when the parent builds a new data array.

```tsx
const { push } = useRouter();
const onItemPress = useCallback((itemId: string) => {
  push(`/items/${itemId}`);
}, [push]);

const ItemRow = memo(function ItemRow({ id, title, onPress }: RowProps) {
  const handlePress = useCallback(() => onPress(id), [id, onPress]);
  return <Pressable onPress={handlePress}><Text>{title}</Text></Pressable>;
});
```

Do not rebuild every item object because an unrelated parent value changed.
`map` and `filter` are valid when the data must change. Memoize the result when
the transformation is expensive or when stable item references let memoized
rows skip work.

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
`GestureDetector` with `Gesture.Tap()` instead, covered in `animations.md`.

---

## Lists

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

### Keep rows cheap

A row can mount many times during a fast scroll. Move repeated parsing,
sorting, aggregation, and formatting out of the row. Do not start one network
request for each mounted row when the screen can load or batch the data. A row
may use context or a query when that ownership is correct, but the subscription
must be narrow enough that unrelated changes do not render every visible row.

Create static `Intl` formatters once at module scope. If the formatter depends
on the active locale or user options, memoize it from those inputs.

```tsx
const shortDate = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' });

function StaticDate({ value }: { value: Date }) {
  return <Text>{shortDate.format(value)}</Text>;
}

function LocalizedDate({ value, locale }: Props) {
  const formatter = useMemo(
    () => new Intl.DateTimeFormat(locale, { dateStyle: 'medium' }),
    [locale],
  );
  return <Text>{formatter.format(value)}</Text>;
}
```

### Describe heterogeneous item families

Use a discriminated item type when one list renders materially different row
families. Give FlashList or LegendList a fast `getItemType` callback so the
virtualizer can recycle a compatible row. Do not use a type for cosmetic
variants that share the same row structure.

```tsx
type FeedItem =
  | { kind: 'article'; id: string; title: string }
  | { kind: 'advert'; id: string; campaignId: string };

const getItemType = (item: FeedItem) => item.kind;
const keyExtractor = (item: FeedItem) => item.id;

<FlashList
  data={items}
  getItemType={getItemType}
  keyExtractor={keyExtractor}
  renderItem={renderItem}
/>
```

Keys must be stable and unique for the data set. Virtualizers recycle row
components. Reset item-specific local state when the item identity changes, or
keep that state outside the recycled row. Check the current
[FlashList usage guide](https://shopify.github.io/flash-list/docs/usage/),
[LegendList API](https://legendapp.com/open-source/list/v3/api/), and
[LegendList guides](https://legendapp.com/open-source/list/v3/guides/) for the
installed library.

---

## Native UI Primitives

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

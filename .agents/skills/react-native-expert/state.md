# State

## Derive presentation values

Store the source value. Derive labels, filtered collections, validation flags,
and other presentation values during render. Do not synchronize derived values
with an effect unless an external system owns the second value.

```tsx
const [items, setItems] = useState<Item[]>([]);
const visibleItems = useMemo(
  () => items.filter((item) => item.visible),
  [items],
);
```

## Use functional setters for dependent updates

When the next value depends on the previous value, pass an updater function.
This rule avoids stale closures and makes consecutive updates compose.

```tsx
setAttempts((current) => current + 1);
setSelectedIds((current) => {
  if (current.has(itemId)) return current;
  const next = new Set(current);
  next.add(itemId);
  return next;
});
```

## Model an optional local override

Use a local override only when the UI can temporarily replace a source value.
Use `local ?? fallback` only when `undefined` or `null` means "follow the
source." Do not use it when those values have a separate business meaning.

```tsx
const [localSelection, setLocalSelection] = useState<string | undefined>();
const selection = localSelection ?? serverSelection;
```

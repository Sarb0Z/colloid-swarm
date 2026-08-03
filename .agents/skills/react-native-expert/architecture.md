# Architecture: modular monolith

## Contents
- A module must not import from another module
- Promote on the second consumer
- Module layout
- Keep the routing layer as routes and composition only
- Business logic in hooks, UI in screens

As an app grows past a handful of screens, organize by **feature module**, not by
technical layer. Two top-level concerns live under `src/`:

- **`src/modules/<feature>/`** — self-contained feature modules. Each module owns
  its screens, components, hooks, services, types, stores, and validations. A
  module must be **deletable** without breaking unrelated features.
- **`src/shared/`** — cross-module primitives (UI building blocks, utilities,
  hooks) used by **two or more** modules.

### A module must not import from another module

If two modules need the same thing, promote it to `src/shared/`.

```
// ❌ BAD - groceries silently depends on recipes
src/modules/recipes/components/RecipeCard.tsx
src/modules/groceries/screens/GroceryList.tsx
  └── import RecipeCard from '@/modules/recipes/components/RecipeCard'
// Deleting or refactoring recipes now breaks groceries

// ✅ GOOD - promote the shared primitive, both import from src/shared
src/shared/ui/recipe-card/RecipeCard.tsx
src/modules/recipes/screens/RecipeList.tsx
  └── import { RecipeCard } from '@/shared/ui/recipe-card'
src/modules/groceries/screens/GroceryList.tsx
  └── import { RecipeCard } from '@/shared/ui/recipe-card'
```

### Promote on the second consumer

- Used by 1 module → keep it **inside** that module.
- Used by 2+ modules → move to `src/shared/`.
- Don't pre-promote. Move things when the second consumer appears, not before —
  premature sharing creates coupling and an unclear ownership story.
- If a "shared" file ends up used by only one module after a refactor, demote it
  back into that module.

### Module layout

```
src/modules/recipes/
  screens/        ← presentational, mounted by src/app/ routes
  components/     ← module-local UI
  hooks/          ← business logic
  services/       ← API calls
  stores/         ← module-local state
  types/
  index.ts        ← public surface of the module (keep it small)
```

Only what a module exports from `index.ts` is its public API.

### Keep the routing layer as routes and composition only

If using Expo Router, `src/app/` is the **routing/composition** layer — route
files, `_layout.tsx` shells, and screen wiring only. It must not contain feature
UI, business logic, state, or data fetching.

```tsx
// ❌ BAD - src/app/(tabs)/recipes/index.tsx owns the whole feature
export default function RecipesScreen() {
  const [search, setSearch] = useState('');
  const query = useRecipeSearch(search);
  const allRecipes = useMemo(
    () => query.data?.pages.flatMap(p => p.recipes) ?? [],
    [query.data],
  );
  // …200 lines of UI, hooks, handlers, JSX…
  return <View>…</View>;
}
// Can't be reused, can't be tested without the router, unmaintainable

// ✅ GOOD - route file composes a module screen
// src/app/(tabs)/recipes/index.tsx
import { RecipesScreen } from '@/modules/recipes';

export default function RecipesRoute() {
  return <RecipesScreen />;
}
```

Most route files end up as a single-line render of a module screen, with maybe a
`<Stack.Screen options={…} />` for header config.

### Business logic in hooks, UI in screens

Screens are **presentational** — they assemble UI and bind values/handlers from
hooks. All business logic (fetching, derivations, mutations, validation,
navigation decisions, side effects) belongs in a `use<Screen>` hook co-located
with the screen. This keeps screens readable as JSX and lets logic be tested
without mounting a render tree.

```tsx
// ✅ GOOD - hook owns the logic
// src/modules/recipes/hooks/useRecipesScreen.ts
export function useRecipesScreen() {
  const router = useRouter();
  const [search, setSearch] = useState('');
  const debouncedSetSearch = useDebouncedCallback(setSearch, 500);
  const query = useRecipeSearch(search);

  const recipes = useMemo(
    () => query.data?.pages.flatMap(p => p.recipes) ?? [],
    [query.data],
  );

  const onEndReached = useCallback(() => {
    if (query.hasNextPage && !query.isFetchingNextPage) query.fetchNextPage();
  }, [query]);

  const onRecipePress = useCallback(
    (recipe: RecipeDetail) => router.push(`/recipe/${recipe.id}`),
    [router],
  );

  return { recipes, query, debouncedSetSearch, onEndReached, onRecipePress };
}

// src/modules/recipes/screens/RecipesScreen.tsx - mostly JSX
export function RecipesScreen() {
  const { recipes, query, debouncedSetSearch, onEndReached, onRecipePress } =
    useRecipesScreen();

  return (
    <View>
      <SearchBar onChange={debouncedSetSearch} />
      <LegendList
        data={recipes}
        renderItem={({ item }) => (
          <RecipeCard {...item} onPress={() => onRecipePress(item)} />
        )}
        onEndReached={onEndReached}
        estimatedItemSize={120}
      />
    </View>
  );
}
```

Heuristic: if you reach for `useState`/`useMemo`/`useEffect`/`useCallback`,
mutations, or query hooks alongside a large render tree in the same file — extract
a `use<Screen>` hook.

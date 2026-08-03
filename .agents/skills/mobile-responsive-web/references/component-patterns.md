# Component-Specific Responsive Patterns

## Contents
- Container-Query Cards
- Hover / Pointer-Aware Interactions
- Hero Section
- Search Form
- Card Grids
- Mobile Menu
- Mobile Scroll Indicator
- Section Dividers
- Search Results Page
- Footer

For foundational techniques (container queries, `svh`/`dvh`, fluid
typography, hover/pointer queries, safe-area insets), see
`modern-css.md`. For images, see
`responsive-images.md`. This file documents the
component shapes this codebase uses.

## Container-Query Cards

When a card must live in a narrow sidebar *and* a wide main column,
switch to a container query so the component self-adapts instead of
depending on viewport breakpoints:

```tsx
// Parent that hosts the card defines the containment
<div className='@container'>
  <article className='flex flex-col gap-3 @md:flex-row @md:gap-6'>
    <div className='aspect-[16/10] @md:aspect-square @md:w-1/3'>
      <Image … />
    </div>
    <div className='@md:flex-1'>
      <h3 className='text-lg @md:text-xl'>{trip.title}</h3>
    </div>
  </article>
</div>
```

Requires `@tailwindcss/container-queries` in the Tailwind plugins array.

## Hover / Pointer-Aware Interactions

Never rely on hover to reveal critical information — phones cannot hover.
Gate visual hover effects and expand touch padding for coarse pointers:

```tsx
<button
  className={cn(
    'min-h-11 rounded-xl px-4',
    // Hover effect only where supported
    'hover:shadow-lg hover:-translate-y-0.5',
    // Extra breathing room on touch
    'pointer-coarse:min-h-12 pointer-coarse:px-5',
  )}
>
```

## Hero Section

### Title

```tsx
<h1
  className='break-words font-bold leading-tight tracking-tight text-white'
  style={{
    fontSize: 'clamp(1.375rem, 4vw + 0.5rem, 4rem)',
    textShadow: '0 2px 10px rgba(0, 0, 0, 0.3)',
  }}
>
```

- `break-words` prevents mid-word breaks
- `clamp()` minimum should be small enough for 375px width
- `text-balance` causes word-breaking — avoid it

### Stats Grid

```tsx
<div className='grid grid-cols-2 gap-4 pt-4 sm:gap-6 sm:pt-6 md:grid-cols-4 md:gap-8 md:pt-8'>
  {stats.map(stat => (
    <div className='text-center'>
      <div className='text-xl font-bold sm:text-2xl md:text-3xl'>
        {stat.value}
      </div>
      <div className='text-xs text-white/80 sm:text-sm'>
        {stat.label}
      </div>
    </div>
  ))}
</div>
```

### Trust Badges (Hero)

```tsx
<div className='grid grid-cols-2 gap-2 sm:gap-4 md:grid-cols-4'>
  {badges.map(badge => (
    <div className='flex flex-col items-center gap-1 rounded-xl p-2 sm:flex-row sm:gap-2 sm:p-3'>
      <div className='flex h-7 w-7 items-center justify-center rounded-lg sm:h-8 sm:w-8'>
        <badge.icon className='h-3.5 w-3.5 sm:h-4 sm:w-4' />
      </div>
      <div className='w-full text-center sm:text-left'>
        <div className='text-[11px] font-semibold sm:text-xs md:text-sm'>
          {badge.title}
        </div>
        <div className='text-[9px] sm:text-[10px] md:text-xs'>
          {badge.description}
        </div>
      </div>
    </div>
  ))}
</div>
```

- Use `flex-col` on mobile for more horizontal text room
- Use `break-words` instead of `truncate`
- Shrink icon and text sizes progressively

## Search Form

### Mobile-First Layout

```tsx
<Card className='border-0 bg-white/95 shadow-2xl backdrop-blur-xl'>
  <form className='space-y-3'>
    <div className='grid grid-cols-1 gap-3 md:grid-cols-[2fr_1.2fr_1fr_auto] md:gap-4'>
      {/* Location — label only on desktop */}
      <FormItem>
        <FormLabel className='hidden md:block'>Destination</FormLabel>
        <div className='relative'>
          <MapPin className='absolute left-3.5 top-1/2 h-4 w-4 -translate-y-1/2 md:hidden' />
          <LocationAutocomplete
            placeholder='Where do you want to go?'
            className='h-11 rounded-xl'
          />
        </div>
      </FormItem>

      {/* Dates — label only on desktop */}
      <FormItem>
        <FormLabel className='hidden md:block'>Dates</FormLabel>
        <Button
          variant='outline'
          className='h-11 w-full justify-start rounded-xl border-border/40'
        >
          <CalendarIcon className='mr-2.5 h-4 w-4 text-muted-foreground/70' />
          <span>{value ?? 'Add dates'}</span>
        </Button>
      </FormItem>

      {/* Travelers */}
      <FormItem>
        <FormLabel className='hidden md:block'>Travelers</FormLabel>
        <Input
          type='number'
          leftIcon={<UsersIcon className='h-4 w-4 text-muted-foreground/70' />}
          className='h-11 rounded-xl pr-10'
        />
      </FormItem>

      {/* Search button */}
      <div className='flex items-end'>
        <Button className='cta-glow h-11 w-full rounded-xl text-sm font-semibold sm:text-base'>
          <SearchIcon className='mr-2 h-4 w-4' />
          Search
        </Button>
      </div>
    </div>
  </form>
</Card>
```

Key principles:
- Labels hidden on mobile (`hidden md:block`)
- Icons shown on mobile (`md:hidden`)
- `h-11` inputs for touch targets
- `rounded-xl` for premium feel
- `cta-glow` class for primary action

## Card Grids

### Standard Card Grid

```tsx
<StaggeredList className='grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3' stagger={0.08}>
  {items.map(item => (
    <StaggeredItem key={item.id} className='h-full'>
      <TripCard trip={item} variant='default' />
    </StaggeredItem>
  ))}
</StaggeredList>
```

### Featured Card

```tsx
// Image container MUST have aspect ratio on mobile
<div className={cn(
  'relative overflow-hidden',
  isFeatured ? 'aspect-[16/10] md:aspect-auto md:w-1/2' : 'aspect-[4/3]'
)}>
```

Without `aspect-[16/10]` on mobile, the featured card image collapses to 0 height.

## Mobile Menu

### Full-Screen Slide Panel

```tsx
// Backdrop
<motion.div
  className='bg-black/40 fixed inset-0 z-40 backdrop-blur-md lg:hidden'
  initial={{ opacity: 0 }}
  animate={{ opacity: 1 }}
  exit={{ opacity: 0 }}
/>

// Panel
<motion.div
  className='bg-background fixed bottom-0 right-0 top-0 z-50 w-full max-w-sm overflow-auto shadow-2xl lg:hidden'
  initial={{ x: '100%' }}
  animate={{ x: 0 }}
  exit={{ x: '100%' }}
  transition={{ type: 'spring', stiffness: 300, damping: 30 }}
>
  <div className='flex h-full flex-col'>
    {/* Header */}
    <div className='flex items-center justify-between border-b px-6 py-4'>
      <span className='text-lg font-bold'>Menu</span>
      <Button variant='ghost' size='icon' className='h-10 w-10 rounded-full'>
        <X className='h-5 w-5' />
      </Button>
    </div>

    {/* Nav items with stagger */}
    <nav className='flex-1 space-y-1 overflow-auto px-6 py-6'>
      {items.map((item, i) => (
        <motion.div
          key={item.id}
          custom={i}
          variants={{
            hidden: { opacity: 0, x: 20 },
            visible: (i: number) => ({
              opacity: 1, x: 0,
              transition: { delay: i * 0.05, duration: 0.3 }
            })
          }}
          initial='hidden'
          animate='visible'
        >
          <Link className='flex items-center space-x-3.5 rounded-xl p-3.5'>
            <item.icon className='text-primary h-5 w-5' />
            <span className='text-base font-medium'>{item.label}</span>
          </Link>
        </motion.div>
      ))}
    </nav>
  </div>
</motion.div>
```

Key principles:
- Slides from right (`x: '100%'` → `x: 0`)
- Dark blur backdrop
- `max-w-sm` panel (not full-width, feels more controlled)
- Staggered item animations
- `p-3.5` touch targets minimum
- Primary-colored icons for visual hierarchy

## Mobile Scroll Indicator

```tsx
<div className={cn(
  'fixed bottom-5 left-1/2 z-[100] -translate-x-1/2',
  'flex sm:hidden',
  'items-center gap-2.5 rounded-full bg-white px-4 py-2.5',
  'shadow-[0_8px_30px_rgba(0,0,0,0.25)] backdrop-blur-xl',
  'border border-white/50',
)}>
  {sections.map((section, index) => (
    <button
      className={cn(
        'rounded-full transition-all duration-300',
        activeIndex === index
          ? 'bg-primary h-2.5 w-7'
          : 'h-2.5 w-2.5 bg-gray-300',
      )}
    />
  ))}
</div>
```

Key principles:
- `z-[100]` — above everything
- `bg-white` (not translucent) for visibility on all backgrounds
- Strong shadow for depth
- Small but tappable dots

## Section Dividers

Ensure dividers don't cause horizontal overflow:

```tsx
// ✅ Safe
<SectionDivider variant='curve' color='mixed' height='md' flip />

// Check that divider SVGs use viewBox and don't have fixed widths
```

## Search Results Page

### Layout: Sidebar + Results Grid

Desktop uses a 4-column grid (1 sidebar + 3 results). On mobile the sidebar
becomes a bottom sheet so results appear immediately.

```tsx
// Results header — filter button for mobile, share/map for desktop
<div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
  {/* Hide outer count on mobile — inner results grid already shows it */}
  <div className="hidden sm:block">
    <h2 className="text-lg font-semibold sm:text-xl">{totalCount} trips found</h2>
    {filters.location && <p className="text-muted-foreground text-sm">in {filters.location}</p>}
  </div>

  <div className="flex items-center gap-2">
    {/* Mobile filter drawer trigger */}
    <Sheet …>
      <SheetTrigger asChild>
        <Button variant="outline" size="sm" className="lg:hidden">
          <SlidersHorizontal className="mr-2 h-4 w-4" />
          Filters
          {activeFiltersCount > 0 && <Badge variant="secondary" className="ml-2">{activeFiltersCount}</Badge>}
        </Button>
      </SheetTrigger>
      <SheetContent side="bottom" className="h-[85vh] rounded-t-2xl">
        <FacetedNavigation … />
      </SheetContent>
    </Sheet>

    {/* Desktop-only controls */}
    <Button className="hidden sm:flex" …>Share</Button>
    <Button className="hidden sm:flex" …>List</Button>
    <Button className="hidden sm:flex" …>Map</Button>
  </div>
</div>

// Main grid — sidebar hidden on mobile
<div className="grid grid-cols-1 gap-8 lg:grid-cols-4">
  <div className="hidden space-y-6 lg:col-span-1 lg:block">
    <SavedSearches />
    <FacetedNavigation … />
  </div>
  <div className="lg:col-span-3">
    <SearchResultsGrid … />
  </div>
</div>
```

### Results Sub-Header (inside SearchResultsGrid)

Always visible, includes count + view toggle + sort:

```tsx
<div className="flex flex-col justify-between gap-3 sm:flex-row sm:items-center">
  <div className="flex items-center gap-3">
    <div className="flex items-baseline gap-2">
      <span className="text-primary text-xl font-bold sm:text-2xl md:text-3xl">{count}</span>
      <span className="text-base font-medium sm:text-lg md:text-xl">trips found</span>
    </div>
    {/* View toggle — visible on all screens */}
    <div className="flex rounded-lg border p-1">
      <Button variant={grid ? 'default' : 'ghost'} size="sm" className="px-2.5 sm:px-3">
        <GridIcon className="h-4 w-4" />
      </Button>
      <Button variant={list ? 'default' : 'ghost'} size="sm" className="px-2.5 sm:px-3">
        <ListIcon className="h-4 w-4" />
      </Button>
    </div>
  </div>

  {/* Sort controls — wrap on very small screens */}
  <div className="flex flex-wrap items-center gap-2">
    <span className="text-muted-foreground text-sm">Sort by:</span>
    <Select …>
      <SelectTrigger className="h-9 w-28 sm:w-32">…</SelectTrigger>
    </Select>
    <Button variant="outline" size="sm" className="h-9 px-2">
      <SortIcon className="h-4 w-4" />
    </Button>
  </div>
</div>
```

Key principles:
- Sidebar `hidden lg:block`, filters in bottom sheet on mobile
- Outer count `hidden sm:block` to avoid duplication with inner count
- View toggle visible on all screens (was `hidden sm:flex`)
- Sort controls use `flex-wrap` and compact heights (`h-9`) on mobile
- Filter button shows active count badge

## Footer

```tsx
<footer className='container mx-auto px-4 py-10 md:py-12'>
  <div className='grid grid-cols-1 gap-8 md:grid-cols-2 lg:grid-cols-5'>
    {/* Company info — full width on mobile */}
    <div className='lg:col-span-2'>
      ...
    </div>
    {/* Link columns stack naturally */}
  </div>
</footer>
```

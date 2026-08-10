---
applyTo: '**/app/**/*.tsx,**/app/**/*.ts,**/src/app/**/*.tsx,**/src/app/**/*.ts,**/next.config.*,**/middleware.ts'
paths:
  - '**/app/**/*.tsx'
  - '**/app/**/*.ts'
  - '**/src/app/**/*.tsx'
  - '**/src/app/**/*.ts'
  - '**/next.config.*'
  - '**/middleware.ts'
detect:
  - '**/next.config.*'
---

# Next.js App Router Rules

## Business Invariants
- A component is a Server Component until a file declares `'use client'`. Declare it at the entry point of an interactive subtree, never at the top of a shared leaf that server code also renders.
- `'use client'` marks a boundary, not a file. Everything imported below it joins the client bundle, so a secret, a database client, or a server-only SDK reached from a client file ships to the browser.
- Props that cross the boundary must serialize. Pass a promise into a Client Component and resolve it with `use()` inside a `<Suspense>` boundary rather than awaiting it in the parent and blocking the render.
- `fetch` does not cache by default. State the intent on every call: `cache: 'force-cache'` to reuse across requests, `next: { revalidate: <seconds> }` for a time bound, and nothing for a per-request read.
- A Server Action mutates on the server and is reachable by any caller who can reach the route. Authorize inside the action itself. The component that renders the form is not the authorization boundary.
- `middleware.ts` runs on every matched request. Keep it to routing and header work; a database call there pays its cost on every navigation.
- Where the backend publishes an OpenAPI or Swagger document, generate the client from it — types, hooks, and validation schemas together — and regenerate on every backend change. `orval` covers this shape: it emits TypeScript models, React Query hooks, Zod schemas, and MSW mocks from one spec. A hand-written client holds a second copy of the contract, and the copies diverge at runtime rather than at build.

## Abnormal Cases and Rationale
- A `'use client'` file that imports a server-only module fails at build with an unhelpful trace. Mark the module with `import 'server-only'` so the error names the real boundary crossing.
- An environment variable reaches the browser only through the `NEXT_PUBLIC_` prefix. A secret named with that prefix is published, and the build reports nothing.

## Out of Scope
- Do not restate visual design rules here. `.agents/rules/frontend.md` owns those.

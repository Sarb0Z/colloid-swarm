---
applyTo: '**/src/**/*.module.ts,**/src/**/*.controller.ts,**/src/**/*.service.ts,**/src/**/*.dto.ts,**/src/**/*.guard.ts,**/src/main.ts'
paths:
  - '**/src/**/*.module.ts'
  - '**/src/**/*.controller.ts'
  - '**/src/**/*.service.ts'
  - '**/src/**/*.dto.ts'
  - '**/src/**/*.guard.ts'
  - '**/src/main.ts'
detect:
  - '**/nest-cli.json'
---

# NestJS Rules

## Business Invariants
- Every request body, query, and param arrives as a DTO class with `class-validator` decorators. An untyped `any` on a handler signature is an unvalidated boundary.
- The global `ValidationPipe` runs with `whitelist: true` and `forbidNonWhitelisted: true`. Whitelisting alone strips an unknown property in silence; forbidding it makes the caller's mistake visible.
- A controller maps HTTP to a service call and back. It holds no business logic, no query, and no transaction.
- A provider that another module needs is exported by its own module and imported by the consumer. Reaching into another module's file bypasses the injector and the dependency graph stops describing the application.
- A global exception filter registers through `APP_FILTER` in a module's providers, never `useGlobalFilters` in `main.ts`, because only the provider form receives dependency injection.
- A guard decides authorization and returns a boolean or throws. It does not mutate the request beyond attaching the resolved principal.
- The OpenAPI document is generated from the DTOs, never hand-maintained beside them. A hand-written spec is a second source of truth that drifts from the first without failing anything, and every consumer generated from it inherits the drift.

## Abnormal Cases and Rationale
- A circular import between modules resolves at runtime through `forwardRef` and then fails in a test that loads one module alone. Treat the cycle as the finding, not the `forwardRef`.
- An exception thrown outside the request lifecycle — in a scheduled task or a queue consumer — reaches no HTTP filter. Handle it where it is raised.

## Out of Scope
- Do not restate database access rules here. The ORM the application chose owns those.

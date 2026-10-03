---
applyTo: '**/*.ts,**/*.tsx,**/*.mts,**/*.cts'
paths:
  - '**/*.ts'
  - '**/*.tsx'
  - '**/*.mts'
  - '**/*.cts'
detect:
  - '**/tsconfig.json'
---

# TypeScript Rules

## Business Invariants
- These rules govern code that you write or change. Do not migrate untouched code, change compiler or lint configuration, or rename files unless the task asks for it.
- Do not use `any`. At a boundary, take `unknown` and narrow it. A new project compiles with `strict: true`. In an existing project, keep new code free of strict-mode errors.
- Use `as` only directly after validation at a boundary. `as const` is allowed. Use the non-null `!` only where a comment on the same line states the invariant. Do not use `@ts-ignore` or `@ts-expect-error`: fix the type.
- A boundary is a process argument, subprocess output, a file, JSON, an IPC message, or the network. Parse and validate there, once, into a typed value. Downstream code trusts the type and does not check it again.
- Model variants as discriminated unions. Exhaust them with a `switch` whose `default` asserts `never`. Prefer string-literal unions to `enum`.
- `undefined` is the absent value. Use `null` only where an external API requires it. Mark data that must not change `readonly`.
- A new parameter that the function needs is mandatory: add it without `?` or a default, and update the call sites. A default is for a parameter that is optional by nature, such as an optional callback or a natural identity like `steepness = 1`. A new tuning constant that suits most callers must be a named constant or a mandatory argument.
- The same test applies to an options object: a field the function needs is a required field. Write overload signatures only for shapes that cannot share one signature.
- A boolean flag may default to `false` only when it adjusts a side aspect of the same operation. When the flag changes what the function means, write a second function with its own name.
- An empty `catch {}` and `.catch(() => {})` are defects. Report the failure through the project's logger, or rethrow it. Converting an error into a default value with `??` or `||` is the same defect.
- Every promise is awaited, returned, or handled. A new project enables the lint rule against floating promises at error level.
- Throw `Error` subclasses for failures that a caller must tell apart, and keep plain `Error` for defects. Never throw a string or a plain object. Set `cause` when you wrap an error.
- Prefer modules of functions and plain data. A class is for an owner of a resource with a lifecycle: a child process, a socket, a lock. Do not write inheritance hierarchies or abstract base classes.
- Pass external effects (subprocess runners, the clock, the filesystem, IPC senders) as parameters at module boundaries. The entry point wires the real implementations, and tests pass fakes. Logic code does not import `node:child_process` or similar.
- Where a project spans processes (Electron main and renderer, server and browser), the shared request and response types live in one module that both sides import. Browser code never imports a Node module, and the IPC boundary is a validation boundary.
- Use `async` and `await`. Use `Promise.all` only for operations that are truly independent. Add `AbortSignal` only where a caller cancels.

## Abnormal Cases and Rationale
- A framework pack wins wherever it conflicts with this pack. Examples: the classes, decorators and injector of NestJS, the default exports and file names of the Next.js and Expo routers, and React error-boundary classes.
- `?` and default values make a new parameter cheap to add and expensive to find later. The mandatory rule moves that cost to the change that introduces the parameter.
- A floating promise loses its rejection: the error never reaches a handler, a log or a test.

## Out of Scope
- Do not restate formatting or style here. The project's formatter and linter own them, and the post-edit hook applies them.
- Do not restate framework rules here. `stack-nextjs.md`, `stack-nestjs.md` and `stack-expo.md` own those, and `frontend.md` owns visual design.
- The scaffold's own sources under `.agents/` follow `.agents/AGENTS.md`.

---
applyTo: '**/*.rs'
paths:
  - '**/*.rs'
detect:
  - '**/Cargo.toml'
---

# Rust Rules

## Business Invariants
- These rules govern code that you write or change. Do not migrate untouched code or change lint configuration unless the task asks for it.
- A new parameter that the function needs is mandatory. Do not use an `Option<T>` parameter or a builder method to avoid updating call sites. Use `Option<T>` only for a value that is absent by nature, such as an optional callback or override. A new tuning constant that suits most callers must be a named constant or a mandatory argument.
- Do not discard a `Result`: not with `let _ = fallible()`, and not with `.ok()` to drop an error. Propagate it with `?`, handle it explicitly, or log it.

## Abnormal Cases and Rationale
- An `Option<T>` parameter that replaces a required input hides it, and the compiler no longer reports the callers that omit it.

## Out of Scope
- Do not restate naming, formatting or lints here. `rustfmt` and `clippy` own them.

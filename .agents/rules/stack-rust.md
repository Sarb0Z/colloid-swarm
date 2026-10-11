---
applyTo: '**/*.rs'
paths:
  - '**/*.rs'
detect:
  - '**/Cargo.toml'
---

# Rust Rules

## Business Invariants
- These rules govern code you write or change. Untouched code stays unmigrated and lint configuration unchanged unless the task asks otherwise.
- A new parameter that the function needs is mandatory. Neither an `Option<T>` parameter nor a builder method stands in for updating the call sites; `Option<T>` is only for a value that is absent by nature, such as an optional callback or override. A new tuning constant that suits most callers must be a named constant or a mandatory argument.
- A `Result` is never discarded, whether by `let _ = fallible()` or by `.ok()` dropping the error: propagate it with `?`, handle it explicitly, or log it.

## Abnormal Cases and Rationale
- An `Option<T>` parameter that replaces a required input hides it, and the compiler no longer reports the callers that omit it.

## Out of Scope
- Naming, formatting, and lints are not restated here: `rustfmt` and `clippy` own them.

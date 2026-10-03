---
applyTo: '**/*.py,**/*.pyi'
paths:
  - '**/*.py'
  - '**/*.pyi'
detect:
  - '**/pyproject.toml'
  - '**/requirements*.txt'
  - '**/setup.py'
---

# Python Rules

## Business Invariants
- These rules govern code that you write or change. Do not migrate untouched code or change project configuration unless the task asks for it.
- A new parameter that the function needs is mandatory: add it without a default, and update the call sites. A default is for a parameter that is optional by nature, such as an optional callback (`on_done=None`) or a natural identity like `steepness=1.0`. A new tuning constant that suits most callers must be a named constant or a mandatory argument.
- A boolean flag may default to `False` only when it adjusts a side aspect of the same operation. When the flag changes what the function means, write a second function with its own name.
- Never use a mutable default (`def f(items=[])`). Default to `None` and create the value inside the function.
- A bare `except:` and `except Exception: pass` are defects. Report the failure through the project's logger, or raise it.
- Pass external effects (subprocess runners, HTTP clients, the clock, filesystem-heavy helpers) as parameters at module and stage boundaries. The entry point wires the real implementations, and tests pass fakes. Logic code does not import `subprocess` or similar.
- Shared test fakes and fixtures live in one support directory: extend them, do not copy them. Mark slow tests that run real tools (with pytest, a `-m slow` style marker) so the default suite stays fast.

## Abnormal Cases and Rationale
- A mutable default is created once, when the function is defined, so every call shares it and one call's changes reach the next.
- A direct `subprocess` import inside logic code removes the seam that a test replaces, so the test must run the real tool or patch a global.

## Out of Scope
- Do not restate environment or package management here. The project's manifest and lockfile own them.
- The scaffold's own scripts under `.agents/` follow `.agents/AGENTS.md`.

---
applyTo: '**/*.py,**/*.pyi,**/*.ts,**/*.tsx,**/*.js,**/*.jsx,**/*.mjs,**/*.cjs,**/*.go,**/*.rs,**/*.rb,**/*.java,**/*.kt,**/*.swift,**/*.dart,**/*.c,**/*.cc,**/*.cpp,**/*.h,**/*.cs,**/*.php,**/*.sh,**/*.sql,**/*.vue,**/*.svelte'
paths:
  - '**/*.py'
  - '**/*.pyi'
  - '**/*.ts'
  - '**/*.tsx'
  - '**/*.js'
  - '**/*.jsx'
  - '**/*.mjs'
  - '**/*.cjs'
  - '**/*.go'
  - '**/*.rs'
  - '**/*.rb'
  - '**/*.java'
  - '**/*.kt'
  - '**/*.swift'
  - '**/*.dart'
  - '**/*.c'
  - '**/*.cc'
  - '**/*.cpp'
  - '**/*.h'
  - '**/*.cs'
  - '**/*.php'
  - '**/*.sh'
  - '**/*.sql'
  - '**/*.vue'
  - '**/*.svelte'
---

# Code

This rule governs code in every stack; it loads once a session opens a code file. A stack pack's own lines add to it.

## Principles

In priority order; resolve conflicts top-down.

1. **Gall's Law.** Build one working thing at a time. "Complete" means the current unit works end to end, not that later phases are scaffolded.
2. **YAGNI.** Implement only what is needed now. YAGNI bounds *what* is built; the production bar governs *how well*.
3. **Unix Philosophy.** Small modules, one responsibility each, the fewest layers that solve the problem. Compose behavior from small pieces rather than inheritance hierarchies. An open-ended category — content, configuration, variants — is data read by a small interpreter; a closed one is plain code.
4. **DRY, after YAGNI.** Shared operations belong somewhere broadly reachable, but no helper is extracted for a single caller on speculation.

## Errors fail loudly

No error is swallowed in code you write or change: it is logged through the project's logger or raised; a hook that must not block reports on stderr and exits 0. Add no speculative handling — trust internal code and framework guarantees, and validate at each system boundary on the side that enforces it: user input, external APIs, files, other processes. A user-facing service answers a user's mistake with a specific error saying what to fix and reserves a generic internal error for defects and infrastructure; a new path that normal use can make fail gets its own error. The stack packs give the language-specific forms.

## Craft

- **Comments.** Write for a reader who never saw the old code. A comment says what the code cannot — a non-obvious why, a subtle constraint, a surprising trade-off, or a signpost over a long linear process. Keep history only when it guards a real regression. No tombstones: nothing describes removed or replaced behavior.
- **Gates over prose.** When a defect class recurs, encode it as a lint rule, test, or merge-gating CI check rather than an instruction. Delete rules that police only style; keep the rules that catch defects. Propose the change when tooling lets a class through or costs edits without catching anything. Prefer strongly typed, explicit, convention-heavy, well-documented frameworks and generators over hand-written glue.
- **No backwards compatibility.** Delete stubs, dead code, and replaced paths outright.
- **Latest stable.** Use the latest stable version existing constraints allow, name the constraint that forces an older one, and verify versions rather than recall them.

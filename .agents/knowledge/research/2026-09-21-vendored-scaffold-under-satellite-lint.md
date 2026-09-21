---
date: 2026-09-21
subject: Whether a satellite's own lint command reads the vendored `.agents/` tree — measured in two JS/TS targets during their transplants; both answer no, by different mechanisms, so a blanket ignore would be dead config
kind: research
source: commands run in MemoGo and Parchi, recorded below
---

# The vendored scaffold under a satellite's lint

A standing breadcrumb claimed that a JavaScript or TypeScript satellite lints
the vendored scaffold after a transplant, that the bundled `security-mcp` build
trips `@typescript-eslint/no-this-alias`, and that the whole repository's lint
therefore fails. The proposed remedy was an `.agents/**` ignore shipped with the
kit.

Two transplants on 2026-09-21 measured it. Neither target's lint reads the tree,
and the reasons differ, which is what makes a blanket remedy wrong.

## MemoGo — flat config skips dot-directories

`~/Projects/MemoGo/mobile-app`, ESLint 9 flat config via `eslint-config-expo`,
lint command `expo lint`.

- `bun run lint` after the full transplant: exit 0, no findings.
- `npx eslint '.agents/mcp-servers/security-mcp/src/**/*.ts'`: 68 files linted,
  9 errors.

So the errors are real and reachable, but only when a path names the directory.
ESLint's flat config does not descend into dot-directories otherwise.

## Parchi — the lint runner has a fixed directory list

`~/Projects/Parchi/parchi`, legacy `.eslintrc.json` (`next/core-web-vitals`,
`next/typescript`) on ESLint 8, lint command `next lint`.

Legacy config does not carry the flat-config dot-directory behaviour, so the
first mechanism does not apply. The outcome is the same for a different reason:
`next lint` with no `dirs` override covers Next.js's default list — `app`,
`pages`, `components`, `lib`, `src` — and a root-level `.agents/` is outside it.

Measured: `npm run lint` reports errors in five of this repository's own `lib/`
files and names `.agents` zero times.

## What follows

An `.agents/**` ignore shipped in the kit would be dead config in both targets,
and dead config in a lint file is a rule a later reader has to disprove before
removing.

The hazard needs a third shape to bite: a legacy config whose lint script globs
the whole tree, or a script that names the directory. Detect that condition at
transplant time and ignore only there. The `no-this-alias` claim itself was not
reproduced; the 9 errors measured in MemoGo were not categorised by rule.

## Sources

Commands run in each target's working tree on 2026-09-21; no external sources.

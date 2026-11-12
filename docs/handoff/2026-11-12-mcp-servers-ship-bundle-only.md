# Repository-owned MCP servers ship to satellites as their bundle only

Workflow: Scaffold · Stakes: Critical (what every satellite receives of two
servers, and where their supply-chain advisories become visible).

**Gate: passed.** The operator OK'd this plan on 2026-11-12 with these rulings:
Decision 1 (a), the export keeps only the program; Decision 2 (a), turn on
Dependabot alerts for `colloid-swarm`; Decision 3 (a), U5 is in;
Decision 4, research-mcp's licence names the operator alone, as `Sarb0Z`. The
decisions stood in for the `grill-me` interview, as the gate question said.

The ask, verbatim (2026-11-12), after a satellite's Dependabot reported 158
alerts, 105 of them in the two server lockfiles: "It seems like an architecture
problem really." Then: "don't get side tracked regarding mail-platform / fix it in
the scaffold and it will automatically be synced at the next transplant. / plan
out the redesign then get back to me".

## The problem

`.agents/mcp-servers/research-mcp` and `.agents/mcp-servers/security-mcp` run
from one committed bundle each, `dist/server.js`, which carries every runtime
dependency. The export copies each whole folder, so every satellite also
receives the build inputs: `package.json`, `package-lock.json` (about 300
packages per server, build and test tools included), sources, tests and an SBOM.
GitHub's dependency graph reads those lockfiles as the satellite's own
dependencies. Four things multiply the count: inputs ship instead of the
program, two servers duplicate one dependency base, the MCP SDK pulls a web
server stack the bundle never contains, and the carrier, the one place that can
fix them, has Dependabot alerts switched off.

## Findings the plan rests on

Read at `08d8398` by a fresh read-only cell (run `mcp-bundle-plan`, cell
`repo-findings`) and a researcher cell (`external-facts`), and by the lead.
`git diff --stat 08d8398 c5afabf` over every cited path is empty; the plan is
written at `c5afabf`, with no uncommitted change to a cited file.

| # | Claim | Evidence | Status |
|---|---|---|---|
| F1 | The kit carries each server folder whole: the export archives `.agents` from Git, and no dropped path names a server | `.agents/export-scaffold.py:78-93`, `:20-44` | observed |
| F2 | The export reads `debt:` pointers from every `.ts` outside `dist/`; the only one in server code is `research-01-duplicate-ssrf-tables`; `strip_tree` skips every file under `mcp-servers` | `export-scaffold.py:177-188`, `:278-279`; `research-mcp/src/core/url-policy.ts:9` | observed |
| F3 | `merge-kit.py --apply` deletes a file the base kit had and the new kit lacks when the satellite left it unchanged (`removed`); an edited copy is a `conflict` left for a hand merge; a copy the satellite already deleted is skipped. It never removes a directory | `.agents/export/merge-kit.py:208-215`, `:267-268`; `rg 'rmtree\|rmdir'` finds no removal | observed |
| F4 | `merge-kit.py` merges a changed text file three ways with `git merge-file` | `merge-kit.py:169` | observed |
| F5 | No satellite records its base kit yet, and `--find-base` can rank a wrong base | `CLAUDE.local.md`, claims-app 2026-10-15 | inferred |
| F6 | The registry launches `node ${REPO_ROOT}/.agents/mcp-servers/<name>/dist/server.js` with the server folder as `cwd`; research-mcp is on, security-mcp off | `.agents/mcp.json:75-95` | observed |
| F7 | `mcp.py` fails when any record's `args` file or `cwd` folder under the repository is missing, enabled or not | `.agents/mcp.py:134-157` | observed |
| F8 | Both builds bundle to ESM `dist/server.js` with `legalComments: 'none'`; Node knows it is ESM only from the server's `package.json` `"type": "module"`; `engines.node` is `>=22.0.0` | `*/scripts/build.mjs:13-22`; `*/package.json` | observed |
| F9 | research-mcp reads nothing from disk at runtime; security-mcp reads templates and the wordlist from `dist/`, where its build copies them | `rg` over `research-mcp/src` finds no read; `security-mcp/src/core/templates/template-loader.ts:8-13`; `security-mcp/scripts/build.mjs:25-26` | observed |
| F10 | Each bundle copied alone under a parent `package.json` `{"type":"commonjs"}` fails ("SyntaxError: Cannot use import statement outside a module"). With a `dist/package.json` of `{"type":"module"}` beside it, the same `server.js` answers `initialize` and `tools/list` (Node 24.22.2) | lead's probes in `$TMPDIR`, 2026-11-12 | observed |
| F11 | Node takes a `.js` file's module type from the nearest `package.json`; module-syntax detection is on by default only from 22.7.0 | nodejs.org/docs/latest-v22.x/api/packages.html, latest-v24.x, read 2026-11-12 | observed |
| F12 | Renaming the bundle conflicts in a real satellite: a three-way merge of product-37-mobile's `mcp.json` (security-mcp dropped by `drop-server.py`) against base `6489a2f` exits 1 when the carrier renames the `args` path, and 0 without the rename | lead's `git merge-file` probe, 2026-11-12 | observed |
| F13 | The bundles contain the SDK, zod, ajv and fast-uri, and not express, hono or `@hono/node-server` | `rg -c '^// node_modules/<pkg>/' */dist/server.js` | observed |
| F14 | Both servers pin SDK 1.30.0 and zod 3.25.76 and lock fast-uri 3.1.5, with no `overrides` | `*/package.json`; `jq` on each lockfile | observed |
| F15 | zod's GHSA-mrhx-c7xc-m3w5 (memory exhaustion in `$ZodArray` validation) is fixed only in 4.6.6, with no 3.x fix; SDK 1.32.2 is the latest and accepts zod `^3.25 \|\| ^4.0`; the SDK advisories exclude stdio-only servers; fast-uri 3.1.9 is admitted by ajv 8.20.0's `^3.0.1`; npm `overrides` can pin a transitive package | registry.npmjs.org, api.github.com/advisories, docs.npmjs.com, read 2026-11-12 | observed |
| F16 | The servers make 14 zod calls, one of them `z.array`; `z.record` already takes two arguments; `.strict()` appears four times. Whether zod 3's own API has the array flaw was not read | `rg` over both `src/` | observed (calls); the flaw's reach is not read |
| F17 | All 44 advisories in a satellite's research-mcp copy from 2026-08-06 still match the carrier's current lockfile, so a re-sync alone clears none | lead's semver check against the carrier lockfile | observed |
| F18 | Dependabot alerts are off on `Sarb0Z/colloid-swarm` (the API answers "Dependabot alerts are disabled"); `dependabot.yml` asks for monthly version updates of both folders | `gh api …/dependabot/alerts`; `.github/dependabot.yml:6-16` | observed |
| F19 | GitHub's dependency graph parses `package-lock.json` and `package.json`, direct dependencies only without a lockfile; a committed CycloneDX file is not among its inputs. A `package.json` with no dependencies gives it nothing to alert on | docs.github.com dependency-graph pages, read 2026-11-12 | observed for the first sentence (medium confidence on the SBOM); inferred for the last |
| F20 | `provision.sh`, which the kit carries, finds every nested lockfile when the repository root has none and does not skip `.agents/mcp-servers`, so such a satellite's lanes run `npm ci` in both server folders | `.agents/provision.sh:108-115` and its `nested` find; the cell's discovery probe | observed (discovery); the install is inferred |
| F21 | Consumers of the server layout: `test-export.sh:53,179,189-192,220-222,254`; `test-mcp.sh:456-459`; `test-stack-packs.sh:124-134`; `demo/demo.sh:169-178`; `ci.yml` job `servers` (`:276-308`) and job `scaffold`, which runs `test-export.sh` on Node 24 (`:33-35`, `:228`); `export/gitignore-fragment:44,51,52`; `.agents/README.md:211-213`; `export/README.md:88-96,196-201`; the build sections of `research-mcp/README.md:141-165` and `security-mcp/README.md:17-26` | `rg mcp-servers` over the carrier, each line opened | observed |
| F22 | Each server folder carries its own `.gitignore` for `node_modules/`; the carrier's root `.gitignore` has no server rule | `*/.gitignore`; `rg` on `.gitignore` | observed |
| F23 | The bundled packages carry MIT, ISC, BSD-2/3-Clause and one Apache-2.0 licence, and the bundle keeps none of their notices | lockfile `license` of each package named in the bundle; F8 | observed |
| F24 | `research-mcp/LICENSE` is byte-identical to `security-mcp/LICENSE` ("Copyright (c) 2026 Muhammad Ajeel", security-mcp's upstream author). Both were added in `9ecf850` by Sarb0z; research-mcp has no `UPSTREAM.json`; the carrier has no root licence | `git log --follow`; `cmp`; `ls` | observed |
| F25 | `export-scaffold.py` is 324 lines and `test-export.sh` 343 | `wc -l` | observed |

Re-opened by the lead: F1, F2, F3, F6, F7, F9, F20 and F21. The cell's line
numbers for `export-scaffold.py` were wrong; the numbers above are the lead's.

**Constraints.** The registry and every satellite's `mcp.json` stay as they are,
because a changed `args` line conflicts wherever a satellite dropped a server
(F12). A sync deletes only files the satellite left unchanged, never a folder
(F3), so leftovers and conflicts need a written step. The bundle must start
under any parent `package.json` (F10, F11). security-mcp's runtime assets stay
in `dist/` (F9). research-mcp keeps resolving DNS on every hop
(`decisions.md`: `no-dns-cache-in-research-fetches`). The export reads Git, so
it runs from the reviewed commit.

**Open questions.** Decisions 1 to 4 below. The implementation's own checks
settle two more: whether zod 4 keeps `.strict()` lint-clean (the type check and
lint run decide), and whether `npm update` lifts every transitive fix inside
the SDK's ranges (`npm audit` decides; Acceptance 5 gives the fallback).

## Options for the cut

- **A, recommended: the export keeps only the program.** One tuple beside
  `DROPPED_PATHS` lists what a satellite receives of each server: `dist/`,
  `LICENSE`, `README.md`, and `UPSTREAM.json` where present. Everything else
  stays in the carrier. It is the export's existing mechanism, subtraction at
  export, as `stack-packs-carrier` decided for stack packs. The list fails
  closed: a new lockfile or development file cannot reach a satellite, and a
  runtime file placed outside `dist/` is caught by the kit launch test.
- **B: move each server's source out of `.agents/`** into a carrier-root
  `mcp-servers/<name>/` that builds into `.agents/mcp-servers/<name>/dist/`. The
  carrier's `.agents/` would then match what satellites receive, with no list
  to keep. It moves about 200 tracked files and re-points CI, `dependabot.yml`,
  the demo, three test scripts, the debt entry and the bundle check's rebuild.
  The satellite result is the same as A.

## Units

One writer works the units in order, because U1 and U2 both rebuild `dist/`.
Each unit is one commit.

1. **U1: the bundle declares its own module type.** Each `build.mjs` writes
   `dist/package.json` as `{"type":"module"}` beside the bundle. The registry,
   the bundle's name, the tests and the demo stay unchanged (F12). The bundle
   check covers the new file, because it hashes everything in `dist/`.
   Acceptance 2.
2. **U2: clear the advisories inside the bundles.** In both servers: the SDK to
   the latest 1.32.x, zod to the latest 4.x at or above 4.6.6, `npm update` for
   the transitive fixes (fast-uri 3.1.9 and the SDK's web stack), and the direct
   development pins raised past their advisories (vitest, esbuild, eslint,
   typescript-eslint). zod moves a major version because no 3.x release fixes
   F15's advisory and the alert matches by version; whether the servers' one
   `z.array` reaches the flaw under zod 3 is not established (F16). Replace
   `.strict()` with `z.strictObject` if lint flags it. Rebuild `dist/`, then run
   `npm run check` on Node 22 and 24. Acceptance 5.
3. **U3: the export ships the program only** (option A, or B if ruled).
   - **Exporter.** `export-scaffold.py` prunes each server folder to the
     shipped list after `drop_paths`. The debt seed then no longer carries
     `research-01` (F2). `strip_tree` stops skipping server files outside
     `dist/`, and the build sections of both server READMEs move inside
     `colloid-only` markers, so a satellite's README describes the server it
     runs.
   - **Ignore rules.** In `export/gitignore-fragment`, drop line 44
     (`node_modules`) and line 52 (`!…/package-lock.json`), and keep line 51
     (`!…/dist/`).
   - **Transplant steps.** `export/README.md` says satellites receive bundles
     only and that a server changes in the carrier. The transplanting agent
     runs three new sync steps after `merge-kit.py --apply`:
     1. Delete any `.agents/mcp-servers/*/node_modules`.
     2. Resolve a conflict under `.agents/mcp-servers/` by taking the kit's
        side: delete the file outside `dist/`, and take the kit's copy inside
        it (F3, F5).
     3. Remove `research-01-duplicate-ssrf-tables` from the satellite's
        `debt-log.md`.
   - **Scaffold README.** `.agents/README.md:211-213` keeps its build
     instructions inside a `colloid-only` marker and tells satellites the
     bundle arrives by sync.
   - **Other files.** The `test-stack-packs.sh:124-126` comment stops claiming
     satellites carry `tsconfig.json`. `research-mcp/LICENSE` names
     `Sarb0Z` as copyright holder (Decision 4).
   - **Tests.** A new script, `.agents/test-export-servers.sh`, holds
     Acceptance 1 to 4. It is listed in `check-all.sh` inside a `colloid-only`
     marker and added to `DROPPED_PATHS`, keeping `test-export.sh` from
     growing (F25).
   - **Decision record.** Record `server-bundles-only-in-satellites` in
     `.agents/decisions.md`.
   - **Unchanged.** `.agents/AGENTS.md:31` stays as written: it is still true
     in both trees.
4. **U4: the carrier sees the advisories** (Decision 2). Under (a), after
   approval, the lead runs
   `gh api -X PUT repos/Sarb0Z/colloid-swarm/vulnerability-alerts` and
   checks the result. Under (b), a weekly scheduled job in `ci.yml` runs
   `npm audit --omit=dev` in both servers. Acceptance 8.
5. **U5, if Decision 3 rules it in: the bundle carries its notices.** Each
   `build.mjs` turns on esbuild's `metafile`, maps the bundled inputs to their
   packages, and writes `dist/THIRD-PARTY-NOTICES.txt` from each package's
   licence file; the bundle check covers it. Acceptance 10.

Delegation: one `implementer` (medium) lane for U1 to U3, plus U5 if ruled in;
`qa-verifier` on the acceptance; one reviewer plus the disprove pass over the
lane; the lead does U4.

**Seams under test.**
- **The kit's shape** (`test-export-servers.sh`). Catches any manifest with
  dependencies, lockfile or source file reaching the kit; it cannot see runtime
  behaviour.
- **The kit's launch** (the same script, Node 24 in CI's `scaffold` job).
  Catches a bundle that needs a file outside `dist/` at startup, or one whose
  module type depends on a parent `package.json`. It misses files read only
  during a tool call; security-mcp's templates are such files, and they live in
  `dist/` by construction.
- **Migration by sync** (the same script). The old-shape kit is built from the
  new kit plus HEAD's full server folders (`git archive HEAD
  .agents/mcp-servers`), which matches what earlier exports shipped and works
  in CI's shallow clone. It is synced into two satellites: one unchanged, and
  one with security-mcp dropped by `drop-server.py`, registry record included,
  the state product-37-mobile is in (F12). Catches removals that don't reach the
  satellite, a registry that doesn't merge, and `mcp.py` rejecting the result.
  It misses conflicts from a wrong base in real satellites, which the README
  step handles.
- **The servers' own checks** (CI job `servers`). Catches zod 4 and SDK breaks
  that the vitest suites reach; it misses live network behaviour.
- **A live tool call.** Catches launch and configuration regressions end to end.

## Acceptance

1. In a kit exported from the landed commit:
   - `fd -H -t f . <kit>/.agents/mcp-servers` lists only `<name>/dist/**`,
     `<name>/LICENSE`, `<name>/README.md` and `security-mcp/UPSTREAM.json`.
   - The only `package.json` files in the whole kit are
     `<name>/dist/package.json`, each exactly `{"type":"module"}`.
   - A search for `package-lock.json`, `npm-shrinkwrap.json`,
     `pnpm-lock.yaml`, `yarn.lock`, `bun.lock(b)` and `sbom.cdx.json` prints
     nothing.
   - Neither server README contains `npm`.
2. With no install, and under a parent `package.json` `{"type":"commonjs"}`,
   `node dist/server.js` run from each kit server folder answers `initialize`.
   research-mcp reports `serverInfo.name` `research-mcp` and the tools
   `fetch_readable,resolve_open_access`; security-mcp reports `security-mcp`
   and `validate_target,security_scan,list_security_prompts`.
3. Both satellite fixtures under "Migration by sync" are synced with
   `merge-kit.py --apply` from the old-shape kit to the new kit. Each:
   - reports every dropped server file as `removed` and
     `<name>/dist/package.json` as `added`;
   - reports no `conflict` and no `hand-merge`;
   - afterwards holds no file under `.agents/mcp-servers/` outside the list in
     1;
   - passes `mcp.py`, which exits 0.

   The fixture that dropped security-mcp keeps it dropped.
4. `provision.sh`'s lockfile discovery on a kit-only fixture with no root
   JavaScript lockfile lists no lockfile under `.agents/`.
5. In each carrier server:
   - `npm ls` shows the SDK at 1.32.2 or later, zod at 4.6.6 or later and
     fast-uri at 3.1.9 or later.
   - `npm audit` exits 0. A transitive fix outside a parent's range gets a
     scoped `overrides` entry. An advisory with no fixed release gets a
     `debt-log.md` entry naming it and why it stays, and the audit output lists
     only those.
   - `npm run check` passes on Node 22 and 24.
6. `.agents/suite.sh` passes on the landed tree.
7. In a fresh carrier session, research-mcp's `fetch_readable` on
   `https://example.com` returns the page's text.
8. Under Decision 2(a), after approval:
   - `gh api repos/Sarb0Z/colloid-swarm/vulnerability-alerts` answers
     204.
   - The open alerts name no manifest under `.agents/mcp-servers/*/dist/`.
   - Alerts on the two server lockfiles are none, or name only advisories
     published after U2.

   Under (b), the scheduled job's first run passes.
9. Not run in this unit: at a satellite's next transplant, its Dependabot
   reports no alert whose manifest sits under `.agents/`.
10. If U5 is ruled in, each kit's `dist/THIRD-PARTY-NOTICES.txt` names every
    package `rg '^// node_modules/'` finds in that bundle, each with its
    licence text.

## Lenses

- **Higher-level abstraction:** treat each server as a built program the
  scaffold ships, like a binary, whose inputs the carrier owns. This changed
  the goal from clearing 105 alerts to no longer shipping the inputs.
- **Irreducible constraints:** a satellite needs a file Node runs with no
  install (F10), that file's runtime assets (F9) and its licence; everything
  else came from the carrier's layout. That produced the shipped list.
- **Carve at the joints:** the joint is between build inputs and the shipped
  program. A cuts it at export and B in the tree; A was chosen because the
  export already subtracts what is carrier-only (F1).
- **Principal architect:** would stop the bundle depending on a
  `package.json` it no longer ships, which gives U1 (F10). It would keep the
  path every satellite registry names, which is why U1 doesn't rename the
  bundle (F12). It would also not ship third-party code without its notices,
  which gives Decision 3 (F23).
- **Implicit state machines:** a satellite's server folder is in one of four
  states: full source (before sync), bundle only (synced), half-synced
  (conflicts left, or a leftover `node_modules`), or pruned. The bundle path is
  the same in every state and the registry never changes, so `mcp.py` passes in
  each. The README steps close the half-synced state.
- **Concession drift:** satellites stop seeing advisories in bundled code, the
  SBOM stays in the carrier, and notices stay absent unless U5 runs. If U4 is
  also declined, nobody sees bundled advisories at all, which is worse than
  today. So Decision 2 cannot be "neither" without accepting that.

## Decisions for the operator

1. **Where the cut sits, and approval of the plan.**
   - (a) Recommended: the export keeps only the program (option A).
   - (b) Move the source out of `.agents/` (option B).
2. **How the carrier sees advisories once satellites don't.**
   - (a) Recommended: turn on Dependabot alerts for `colloid-swarm`.
     It is one outward API call and no code.
   - (b) A weekly CI job runs `npm audit --omit=dev` on both servers. It lives
     in the repository and needs no setting, but it is code to keep.
   - (c) Neither, accepting that bundled advisories go unseen.
3. **Licence notices in the bundle** (found during research, outside the ask).
   - (a) Recommended: include U5. The bundle becomes the only thing satellites
     receive, some satellites belong to other organisations, and the
     licences of the bundled packages ask that copies carry their notices.
   - (b) A separate follow-up.
   - (c) Leave it.
4. **Who holds research-mcp's copyright** (found by the plan review, F24).
   - (a) Name the operator, if research-mcp is original work.
   - (b) Name both, if it reuses security-mcp's upstream code; its SSRF tables
     follow security-mcp's (`research-01-duplicate-ssrf-tables`).
   - (c) Leave the file as it is.

## Out of scope, reported

- `drop-server.py` leaves `mcp_env.<name>` in a satellite's `config.json`,
  after which `mcp.py` fails (cell row F28; pre-existing).
- The two servers duplicate one dependency base (`debt-log.md`
  `research-01-duplicate-ssrf-tables`). One npm workspace with one lockfile
  would halve the carrier's own duplicate alerts.
- The 53 alerts on the satellite's own product code.

## Review

One round at sha256 `b629a53e…dc203` of the first draft (run
`mcp-bundle-plan`, cell `plan-review`, one reviewer on opus): 2 `P1` and 8 `P2`
findings. This text is the plan after these dispositions.

1. `P1`, the rename conflicts in a satellite that dropped a server. Adopted.
   Confirmed by F12's probe. U1 now writes `dist/package.json` and keeps the
   name (F10), and the migration fixture includes a dropped-server satellite.
2. `P1`, the rename misses `manifest.mjs`, the tamper test and `main`/`bin`.
   Adopted by finding 1's redesign: nothing is renamed, and
   `dist/package.json` carries no path for the manifest to normalize.
3. `P2`, grilling replaced without saying so. Adopted: the gate names it.
4. `P2`, the decision record sat in U4. Adopted: it moves to U3.
5. `P2`, satellite READMEs teach a build they cannot run. Adopted in U3:
   `strip_tree` reads server files outside `dist/`, and the build sections are
   marked `colloid-only`.
6. `P2`, Acceptance 5 has no fallback, and the zod migration's reach is
   unstated. Adopted: overrides, then a debt entry; U2 states the reason and
   what is not established.
7. `P2`, satellites keep a debt entry for code they lose. Adopted: U3's third
   sync step.
8. `P2`, two files are over 300 lines. Adopted for `test-export.sh`: the new
   tests go to `test-export-servers.sh`. Declined for `export-scaffold.py`:
   the prune adds one tuple and a short function next to `drop_paths`
   (`:237-243`), the subtraction it extends, and splitting the exporter is
   outside this ask.
9. `P2`, the migration fixture's source is unstated. Adopted: it is built from
   `git archive HEAD .agents/mcp-servers`, and it includes the dropped-server
   satellite.
10. `P2`, research-mcp's licence names security-mcp's author. Escalated as
    Decision 4 (F24).

The reviewer's `AMBIGUITY` on "automatically synced": the steps U3 adds are
part of the transplant procedure, which the transplanting agent runs, so the
operator runs nothing by hand.

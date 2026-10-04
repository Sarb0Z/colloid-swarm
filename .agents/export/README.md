# Transplant guide

The kit is a reviewed snapshot, not an installer. Merge it into the target's
current branch after inspecting that repository's stack, existing instructions,
dirty state, host configuration, and tracked symlinks.

## Preserve first

Back up or inventory existing `AGENTS.md`, `CLAUDE.md`, `.agents/`, `.claude/`,
`.codex/`, `.kimi/`, `.kimi-code/`, `.mcp.json`, and Copilot instruction paths.
Do not overwrite untracked operator state. Keep unrelated host features such as
commands, plugins, output styles, or project-specific agent definitions.

## Build the kit from a commit

`export-scaffold.py` reads `git archive HEAD`, so an uncommitted scaffold fix
does not travel. It prints a warning and still exits 0, and the kit silently
ships the old file. Commit first.

Satellites vendor their own copies of the scaffold and drift behind at
different rates. Propagating one hook or feature is an adaptation against the
target's current copy, never a `cp` from this repository.

Moving a satellite's directory is its own procedure: every host keys session
history by absolute path. Follow `.agents/playbooks/move-project-directory.md`.

## Two passes, not one

A **sync** brings a target to the current kit. An **adaptation** tailors the
kit to the work that repository does: only the skills, servers, and hooks it
needs, each tuned to it, and instructions in the repository's own terms. A
sync without an adaptation leaves a backend carrying a React Native skill and
a browser gate; a repository is not adapted until each item below has been
decided for it, by name.

## Profile the work first

Read before deciding anything: the manifests and lockfiles, the CI workflow
(what it runs, what it refuses to do, and why the comments say so), the lint
config and its per-file exemptions, the test runner config, the deploy path,
every script that touches a hosted system, and the repository's existing
instructions and decision records. Verify each claim you intend to write by
reading the code that makes it true — a rule file that states an invariant
backwards is worse than none, and the hostile review of the plan will look.

Then hostile-review the plan (`.agents/playbooks/hostile-review.md`) before
touching the target. The transplant itself is not high-stakes; gating a
production deploy is, so name the claim QA must reproduce from a fresh clone.

## Sync

A target that already carries the scaffold has edited its copy. Copying the
new kit over it erases those edits, so a re-sync is a three-way merge against
the kit it was last synced from:

```sh
# in the carrier: the commit whose scaffold the target holds most of, byte for byte
python3 .agents/export/merge-kit.py --find-base <target>
git worktree add --detach /tmp/carrier-base <base-commit>
/tmp/carrier-base/.agents/export-scaffold.py /tmp/kit-base
git worktree remove /tmp/carrier-base
.agents/export-scaffold.py /tmp/kit-new
# report first, then write; conflicts carry git merge markers
python3 /tmp/kit-new/export/merge-kit.py <target> /tmp/kit-base /tmp/kit-new
python3 /tmp/kit-new/export/merge-kit.py <target> /tmp/kit-base /tmp/kit-new --apply
```

The merge keeps every file the target deleted (a pruned skill or stack pack
stays pruned) and does not add a carrier file under a directory the target
pruned. It applies a change to the executable bit, and a three-way merge keeps
CRLF line endings. It decides every path before it writes: a kit directory
where the target has a file is a conflict, not a partial apply. It reports the
root `AGENTS.md` for step 3. A first sync has no
base; it copies the kit.

1. Reconcile `export/gitignore-fragment` on every sync, not only the first:
   each carrier release can add a runtime state file, and a missing line means
   the target commits that state. An unanchored
   `dist/` already in the target also matches `.agents/mcp-servers/*/dist/`;
   the negation only works after it. Then confirm nothing the kit ships is
   ignored: `git ls-files --others --ignored --exclude-standard .agents .claude
   .codex .github` must print nothing.
2. Exclude `.agents/` from every linter and formatter that walks the
   repository root — an ESLint flat config's `ignores`, `.prettierignore`,
   ruff's `extend-exclude`. The committed server bundles under
   `.agents/mcp-servers/*/dist/` are not the target's code, and a root
   `eslint .` reports them as errors and turns CI red.
3. Merge `AGENTS.md` by section, never by file. The target owns its sections
   and their position and depth; the kit owns the sections it ships. Three
   traps, each of which has lost repository policy once: a heading below depth
   three inside a replaced section is swallowed with it; a target-owned
   paragraph inside a kit-owned section (an intro sentence, a note under
   Workflow) is replaced with it unless captured first; a repository that nests
   the contract under its own heading needs every kit heading shifted to match.
   After the merge, diff the heading list against the previous commit — a
   missing title is a lost section.
4. Delete every `stack-*.md` whose `detect:` markers the target does not have,
   with its `.claude/rules/` and `.github/instructions/01-*` links. Keep every
   stack it genuinely runs.
5. Never `--delete` on the sync; the target's own CI workflows and skills live
   beside the kit's files.
6. Merge `export/debt-log-entry.md` into the target's debt log when it carries
   entries. The kit drops `.agents/breadcrumbs.md`, `.agents/debt-log.md`, and
   `.agents/decisions.md`; a target's copies are a create, not a merge.
7. A generated host config that carries an absolute path — `.mcp.json`,
   `.codex/config.toml`, `.kimi-code/mcp.json` once a bundled server is
   enabled — must not be tracked; it breaks every other clone. The fragment
   ignores them; `git rm --cached` the ones a target already tracks and say so
   in the commit.
8. Declare `dry_run_commands` for a target that lacks it. A target synced
   before the key existed asks on every `<listed script> --dry-run`. Read the
   argument parser of each script in `hooks.guard_publish.outward_commands`
   and list in `policy.json` under `hooks.guard_publish.dry_run_commands`
   only the scripts whose flag truly rehearses: it reads a bare `--dry-run`
   as on, takes no value word other than a boolean, and writes nothing
   hosted when on. A script that ignores the flag stays off the list.
9. Diff each skill the satellite has edited against the carrier's kit
   (`diff -ru /tmp/kit-new/.agents/skills/<name> <target>/.agents/skills/<name>`).
   The satellite keeps its edits; report the ones that fill a general gap, not
   a local adaptation, so the carrier can fold them back into its own skill.
10. Remove the `export/` directory last; the steps above read from it.

## Adapt

Each item is a decision for this repository, recorded where the repository
will keep it.

- **Rules** (`.agents/rules/<repo>.md`, `applyTo:` and `paths:` frontmatter,
  linked into `.claude/rules/` and `.github/instructions/01-*`): the things an
  agent gets wrong here without being told, each verifiable from the code —
  which directory is the product, which file is the real gate, what the linter
  makes an error and why, what a test marker means, what a loader does when it
  is killed, what deploys and what never must. Scope the globs to every path a
  bullet governs, including the lint config and `.github/`, or the rule does
  not load at the moment it matters. Do not restate what a README or a runbook
  already owns; point at it.
- **Policy** (`.agents/policy.json`, tracked): a hook the repository runs
  without — the browser UI gate in a repository with no browser surface — and
  under `hooks.guard_publish.outward_commands`, every script that writes to a
  hosted system: the deploy script, anything that sets hosted environment or
  secrets, applies a schema to a remote database, or writes hosted rows or
  blobs. Enumerate from `git ls-files`, not from `scripts/` alone — CI
  workflows, package scripts, `tools/`, and `infra/` deploy too — state the
  criterion,
  and leave the read-only ones off. The operator's ignored `config.json` may
  extend this list and never shrinks it. Under
  `hooks.guard_publish.dry_run_commands`, name only the listed entries whose
  code reads `--dry-run` and rehearses; every other listed script asks even
  with the flag, because a script that ignores it deploys anyway. The same
  list governs a committed script that writes to a hosted management API.
  Declare a script only when it reads a bare `--dry-run` as on and takes no
  word other than a boolean as the flag's value.
- **Skills**: keep what the work uses, by name, and delete the rest with their
  host links. A backend keeps security, scalability, code review, research,
  QA, and workloop; a customer web app adds frontend, responsive web, and
  performance; a repository with no marketing surface drops SEO and market
  research; nothing keeps a mobile-native skill without a mobile app. A kept
  skill can name a dropped one in its frontmatter — grep the kit and the
  authored `AGENTS.md` for every dropped name; `.agents/knowledge/README.md`
  and the Workflow section both do.
- **Servers** (`.agents/mcp.json`): `context7` and `research-mcp` on
  everywhere; `playwright` on where there is a browser surface; the rest
  registered and off until a task turns one on. Keep repository-owned bundles
  only when their tools make sense; a removed bundle needs
  `export/drop-server.py <repo> <name>` so the registry does not point at a
  missing executable. A disabled entry masks a same-named user-level server in
  Codex only; Claude still loads the user-level one.
- **Hosts**: keep `.kimi/` only when the target uses Kimi. Preserve the
  target's CI and adapt its checks; never copy this repository's workflow
  over it. To drop Kimi, remove all of these together, or the kit text names
  files that no longer exist:
  - the `.kimi/` directory and the `.kimi-code/` directory;
  - the `.kimi-code/mcp.json` and `.agents/.kimi-pending-findings-*` lines in
    `.gitignore`;
  - the Kimi column of the host table at the top of `.agents/README.md`, and
    the `.kimi-code/mcp.json` cell in the `mcp.json` row;
  - the Kimi sentences in `.agents/README.md`: the Claude, Codex, and Kimi
    list in the destructive-command paragraph, "Codex and Kimi have no"
    (the denied-tool and background-flag paragraphs), the `SubagentStart`
    clause in the parallel-writers paragraph, and the `AgentSwarm` sentence.
  Then run `grep -rniE 'kimi' .agents AGENTS.md` and decide each remaining hit;
  hook and test code that names Kimi as one adapter may stay.
- **Runtime**: a Python repository needs `.python-version` for the provisioner
  to build the right venv, and the linter the post-edit hook runs must be in
  the pinned dev requirements — a venv without `ruff` skips the check
  silently, and exit 0 reads as a pass. Let CI install that pin from the file
  rather than restate it.
- **Instructions**: the authored `AGENTS.md` carries the kit's contract plus one
  section in the repository's own words for what governs every session there —
  where the record of decisions lives, when to commit, what needs the owner's
  yes. Machine facts — an absolute path to a sibling folder, an access
  snapshot, a credential path — go to the repository's gitignored
  `CLAUDE.local.md`, never to a committed file.

## Materialize host state

The kit already carries static Claude/Codex/Copilot links and persona files.
After merging:

```sh
python3 .agents/check-layout.py
python3 .agents/mcp.py
```

Inspect `.agents/codex/hooks.json`, then establish project and hook trust:

```sh
python3 .agents/codex/trust-hooks.py "$(pwd)"
```

Run trust one repository at a time because it updates the user's Codex config.
Start a new Claude/Codex/Kimi session after MCP state changes.

## Verify in the target

```sh
python3 .agents/check-layout.py
.agents/lint-skills.sh
python3 .agents/check-stack-packs.py
.agents/test-session-start.sh
python3 .agents/test-guard-destructive.py
python3 .agents/test-wait-gate.py
.agents/test-session-wrap.sh
python3 .agents/test-guard-publish.py
python3 .agents/test-hosted-scripts.py
.agents/test-mcp.sh
.agents/test-codex.sh
```

Then run the target's own focused checks. Drive one deployed hook through its
host adapter and verify the host sees the intended personas and project MCP
records. A parsed file proves syntax; it does not prove host discovery.

Drive the deployed post-edit adapter with a file carrying a real error per
language, using a violation the tool will not auto-fix: `ruff check --fix`
repairs an unused import before the reporting pass, so that reads as success.
Place the probe outside every per-file exemption in the repository's lint
config, and assert on the finding text (`T201`, `no-console`), never on the
exit code. A gate that ran nothing and a gate that passed look identical from
exit 0.

Drive the deployed publish adapter with every invocation form of each listed
script — `./x.sh`, `bash x.sh`, `VAR=1 ./x.sh`, `python3 ../tools/x.py`,
`cd dir && ./x.sh`, `x.sh -n`, `x.sh --dry-run` — and expect an ask; expect
quiet on `cat` and `grep`, and on `--dry-run` only for a script declared in
`dry_run_commands`. Never declare a script to quiet a failing probe: one that
ignores the flag deploys with it. Then `workloop.py init --verify` with the
deploy script and with `rm -rf /`, expecting a refusal that names the guard.

Once committed, have `qa-verifier` reproduce the gating claim from a fresh
clone that carries no `.agents/config.json` and no `CLAUDE.local.md`. A
clone is what every other machine has; a gate that holds only in the working
tree is not a gate. Hostile-review the diff last; its findings land as a
follow-up commit in each repository.

Review `git status --porcelain --untracked-files=all` before staging. Stage only
the intended scaffold and target-instruction paths; never `git add -A` in a
repository that may hold in-flight work.

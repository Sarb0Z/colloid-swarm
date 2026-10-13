# Workloop: the lead designs the delegation

Spec, critical stakes (it changes the parallel-writers gate, the workloop
controller, and contract text). Rulings came from five rounds with the
operator on 2026-10-13; none is open. No build starts before the operator's
OK on this spec.

## The ask

The operator, after the `lq-ui` run did not fit workloop:

> this is an issue in how workloop is designed don't you think
>
> we need to be more conscientious in how we craft the workloop overall as well
> so it can use its discretion to design the delegation strategy in elegant ways
>
> basically the most powerful way manage delegation is still the language in
> workloop skill and other prompts so whatever build should have an eye towards
> that as well
>
> keep in mind bake-offs can get quite expensive

So the language the lead reads (the shape guide, the briefs, the refusals) is
the main deliverable; controller changes serve it, and hold only what language
alone cannot.

## Evidence

### The controller and its language today

- The controller fixes one delegation shape: writing lanes only, each with its
  own worktree, branch, install and exclusive paths fixed at `add-lane`; one
  review verdict per lane; one composed test at `integrate`. Shared files exist
  only from `init`; the target must already be a Git repository; read-only
  cells have no place in a run (`add-lane` needs a worktree, paths and an
  install; `submit` needs a commit).
- The skill (`.agents/skills/workloop/SKILL.md`) is a command manual. It never
  says when to delegate, how to split, how many cells, which model, or what a
  brief must contain. The generated brief differs by role only in its header.
- Defects found along the way: a one-lane run never runs its `--verify` command,
  although its brief says `integrate` does; the lead's per-prompt digest never
  names QA or `check`; a resumed pending lane silently keeps its first paths.

### How delegation actually went (sessions since 2026-09-01)

358 lead sessions, 1,538 dispatches, counted by command from the transcripts:

- One writer plus read-only cells is the norm: 556 writer dispatches against
  982 readers; 62 of 126 delegating sessions used readers only. Only 36
  messages launched laned parallel writers.
- Bake-offs: 0. The `panspermia-mutation` skill (fan-out with selection): 0
  invocations.
- Cross-repository dispatches: 333 (22%).
- The parallel-writers gate refused 17 dispatch episodes; 3 were a real second
  writer. 8 were lanes whose hand-written prompt lacked the brief's exact
  header; 5 were cells dead from a usage limit or a stopped task, still counted.
  Leads deleted the gate's record by hand 11 times.
- Workloop: 45 real runs (28 torn down, 8 deleted from state by hand, 9 open);
  30% have one lane; 42% of lanes were reopened at least once; 72 Bash commands
  rewrote run state by hand, mostly to widen a lane's paths; 28 reviews were
  refused for citing a report outside the repository; about one worker call in
  five was refused.
- Leads learn the controller from `workloop.py --help` (67 calls), not the skill
  (5 loads, 24 reads of its file).
- The operator asked for parallelism or delegation in 42 prompts, 15 of them
  naming a model tier.

### What other harnesses do

- Judgment lives in prompt language: Anthropic's research lead carries
  effort-scaling rules, a default of three subagents and a ceiling, and a
  required brief (objective, output format, tools, boundaries); Claude Code's
  agent-team guide says start with three to five teammates and give each its
  own files. Code holds only the "never": worktree isolation, ownership.
- More coding agents on one repository fail more: CooperBench pairs succeed
  68.6% of the time, three agents 46.5%, four 30%. Messaging cut merge
  conflicts but not failures, 42% of which were an agent acting as if its
  partner's code would not exist. Systems that work fix interfaces up front
  (MetaGPT, CAID, Cursor's planners) and check them at merge.
- Shared files: every package manager documents one order — merge the
  manifest, then re-lock from the base's lockfile. Generated files are rebuilt
  from source and checked with a diff. No agent harness documents more than
  "one owner per file".
- Stacked-diff tools (Gerrit, Graphite, git-branchless) build a dependent on an
  unreviewed parent by tracking which parent version it used and restacking
  when that moves.

## Rulings

| # | Question | Ruling | Record |
|---|---|---|---|
| 1 | How the skill steers the shape | Principles plus named shapes, with defaults and a brief per shape | this spec |
| 2 | What a run coordinates | Every multi-cell job, read-only cells included | `runs-record-every-cell` |
| 3 | Projects outside this repository | Any Git repository; a folder without Git gets a baseline commit first | this spec |
| 4 | Shared files | Manifests and indexes merge; lockfiles and generated files are rebuilt after the merge | `shared-files-merged-or-rebuilt` |
| 5 | Interfaces between lanes | Contract first; the consumer builds while the producer is reviewed | `lane-interfaces-contract-first` |
| 6 | Where lane worktrees live | `.agents/worktrees/<run>/<lane>`, inside the checkout | `lane-worktrees-nest-in-the-checkout` |
| 7 | The running `lq-ui` | Left to the operator's hand merge | — |
| 8 | Recording a read-only cell | A light entry, tracked until it returns | `runs-record-every-cell` |
| 9 | Fan-out numbers | Writers and readers apart | this spec |
| 10 | Bake-offs | Named in the language only, with their cost | this spec |
| 11 | Where the guide lives | `delegation.md` in full, a light touch in the root `AGENTS.md` | `delegation-guide-where-leads-read` |
| 12 | Frictions the mining found | Fixed in this redesign | this spec |
| 13 | Sparse lanes by default | Full checkouts by default; `--sparse` for very large monorepos only | `lane-checkouts-full-by-default` |
| 14 | Where a lone writer works | In the main tree; worktrees only for writers working at once | this spec |
| 15 | How firmly a multi-cell job is a run | By language plus a nudge in the lead's digest; nothing refuses a read-only dispatch | `runs-record-every-cell` |
| 16 | The root contract's size | No hard limit: `lint-contract.py` warns above 24,000 bytes | `contract-size-warns-not-fails` |
| 17 | The root light touch | The drafted sentence, approved as contract text | this spec |
| 18 | Tier follows difficulty, not stakes | Left as it is: the root's tier sentence and `hostile-review.md` unchanged | `cell-tier-wording-unchanged` |
| 19 | Stale lane worktrees | Removed automatically; unsaved work in an abandoned lane is committed to a saved branch first | `stale-lane-worktrees-saved-then-removed` |

## Design

### 1. The shape guide (the language)

The lead designs each delegation before dispatching it, by answering five
questions about the work. The answers pick a shape; shapes combine, and the
lead may depart from them by stating why.

1. Does it change files? No: a **read-only fan-out** — research, review or QA
   cells that return text. Default three cells, up to about ten for broad
   research; each gets one distinct question.
2. Can one writer do it in reasonable time? Yes: **one writer**, plus read-only
   cells around it. This is the default; most delegations are this.
3. Do the parts touch disjoint files and merge in any order? Yes: **parallel
   slices**, one lane each. At most about three writers on one codebase unless
   the lead states why more pay off; the controller's ceiling of eight stays as
   the backstop.
4. Does one part consume an interface another produces? Yes: a
   **contract-first split** — the contract is written before the lanes start,
   and the consumer builds while the producer is reviewed (section 5).
5. Is the choice between approaches worth paying for several times? Only then a
   **bake-off**: every attempt costs its full tokens and time, so prefer read-only
   cells that return competing designs to writers that each build one, keep it
   to two or three, and decide the selection rule before dispatch.
6. Which tier does each cell need? The tier follows how hard the cell's own
   task is, by the root's tiers.

Each shape carries one cost line the lead weighs: a read-only cell costs its
tokens only; the lone writer adds nothing to the checkout; each extra writer
adds a worktree, an install, a review and a merge (measured 2026-10-13 on this
machine, real disk: about 6 s and 0.26 GB per lane here, 7 s and 0.24 GB on
`food-app-core`, 12 s and 0.9 GB on `claims-app`); a bake-off pays every attempt
in full.

Every brief states: the objective and why; what the cell owns and what it must
not touch; the contract it builds against, if any; the narrowest acceptance it
runs; what it returns and in what shape; when to stop and report instead of
widening. The controller writes the brief from the run's shape; the skill says
what each field means and shows one example per shape in reference files
beside `SKILL.md`, which keeps the skill under `lint-skills.sh`'s 500-line
cap.

Where it lives (ruling 11):

- `.agents/claude/delegation.md`: the six questions, the shapes and the
  numbers, as the delegation bullet the lead reads every session.
- Root `AGENTS.md`, Delegation paragraph, a light touch (ruling 17): two sentences naming the guide and the default shape, for
  every host.
- The workloop skill: the full guide, the brief fields with one example per
  shape, and the controller procedure under each shape that needs one.
- `workloop.py --help` and `init` print the shapes in one line each;
  the parallel-writers gate's second-writer refusal names them.

### 2. A run records every cell

A run is one multi-cell delegation, kept from plan to verified result.

- `init` records the objective, the shape, and the composed test as today.
- Writers are lanes (`add-lane`). A lane added while no other lane of the run is
  active works in the main tree, committing on the current branch: no worktree,
  no install, nothing to merge (ruling 14). It records no branch and no
  worktree, so `teardown` removes neither, and its work is the commit range
  from the run's base. `check` verifies it by running the composed test in the
  main checkout; no integration worktree is made. A lane added while another is
  active gets a worktree (section 6), and `integrate` merges and verifies the
  worktree lanes with the main tree's commits as their base.
- The one-writer shape is one command plus the dispatch:
  `init <run> --objective … --verify … --lane <name> --paths …` records the
  run and its main-tree lane together. The skill states each shape's command
  sequence and its length.
- The guide says a multi-cell job is a run; nothing refuses a read-only dispatch
  outside one (ruling 15). The gate notes each dispatch that carries no run
  header, and the lead's per-prompt digest names them: "3 cells this turn
  outside any run".
- A read-only cell is a light entry:
  `workloop.py add-cell <run> <name> --role research|review|qa --model <model>`.
  `brief <run> <name>` prints its prompt, opening `READ-ONLY`; when it returns,
  `workloop.py returned <run> <name> --result <path or "reply">` records where
  its result went; `returned <run> <name> --failed '<reason>'` records a cell
  that died or was stopped without returning. `status` and the lead's digest
  list cells still out, and `check` refuses to close the run while any is.
- A lane records its model (`add-lane --model`), printed in its brief and in
  `status`.

### 3. Projects outside this repository

`init --repo <dir>` accepts any Git repository, as today. A folder without Git
is refused with the commands that give it a baseline commit
(`git -C <dir> init && git -C <dir> add -A && git -C <dir> commit -m baseline`),
and the skill teaches that as the first step for an outside project. Run state
stays in the lead's checkout, where the gate and the digest read it.

### 4. Shared files

- `workloop.py share <run> <path> [--rebuild '<command>']` declares a shared
  file at any point in the run; `init --shared` stays as the same declaration
  at the start. `share` refuses a path a lane owns. A rebuild command passes
  the same guard as `init --verify` (`workloop_git.guard_command`) when it is
  declared, because `integrate` later runs it where no hook sees it.
- Without `--rebuild` (manifests, indexes, READMEs): lanes edit it, Git merges
  it at `integrate`, and a conflict stops `integrate` naming both lanes.
- With `--rebuild` (lockfiles, generated code): lanes may change it in their
  worktrees and test with that. `integrate` merges every lane with each rebuild
  path resolved to the base's copy, so two lanes' lockfiles never conflict;
  then it runs the rebuild commands, commits their result, provisions from the
  rebuilt lockfile, and runs the composed test. `uv lock` from the base's lockfile keeps the base's
  versions; `npm install --package-lock-only`, `pnpm install` and
  `bun install` re-lock likewise.
- The brief names each shared file with its rule.

### 5. Contracts between lanes

- The lead commits the contract (types, a schema, sample data) first, then runs
  `init`, which pins that commit as the run's base, and names it:
  `add-lane <consumer> --depends-on <producer> --contract <path>`, which
  refuses a path absent at the base.
- Where the lead cannot know the contract, the producer drafts it as a shared
  file, and the consumer acknowledges its exact version
  (`workloop.py ack-contract <run> <lane> <path>` records its hash) before
  building; `submit` refuses a consumer whose contract changed since.
- The consumer may claim once the producer has submitted (`review` or
  `reviewed`), not only after its review is accepted. The controller records
  the producer commit the consumer's branch is built on (`built_on`). The
  lead's per-prompt digest compares `built_on` with the producer's tip and,
  when the producer moved or its review reopened, sends the consumer an
  acknowledgement-required message; messages the controller originates skip
  `send`'s `--supervised` requirement. The controller refuses the consumer's `submit`, an accepting
  `review`, and `integrate` until the producer is `reviewed` and `built_on`
  equals its accepted commit.
- A consumer that needs a stand-in before the producer's code exists declares
  it: `add-lane --provisional <path>`. `integrate` refuses while a provisional
  file remains.
- The consumer's test of the contract is part of the composed test.

### 6. Lane worktrees

- `add-lane` without `--workspace` places the lane at
  `.agents/worktrees/<run>/<lane>`; `/tmp` and `/private/tmp` are refused.
  `.agents/worktrees/` joins the scaffold's `.gitignore` and the export's
  gitignore fragment.
- The parallel-writers gate decides whether a path is in the checkout by the
  nearest Git working tree above it, read with `git rev-parse --show-toplevel`
  from the path's directory, not by a `.git` file, which a submodule also
  holds: a path under a nested lane worktree belongs to that worktree, not the
  checkout. This applies to the lead's own edits, to `OUTSIDE` cells' writes,
  and to the lane check behind a brief. A worktree of this repository nested
  this way is still refused as a `WORKSPACE`.
- `.claude/worktrees/` special cases: the hook lookup's fallback, which sends a
  hook run inside a nested worktree to the main checkout's adapter, learns
  `.agents/worktrees/` too, so a lane's hooks read the run state where it
  lives. `worktree-provision.sh` and `worktree-sessions.sh` serve Claude Code's
  own `EnterWorktree` sessions and stay as they are.
- A tool that walks the checkout without honouring `.gitignore` sees nested
  lanes. Measured 2026-10-13: `git status` and `rg` unchanged; this
  repository's, `food-app-core`'s and `claims-app`'s own test discovery unchanged;
  but an unanchored vitest glob found 1,332 test files with three full lanes
  against 333 without. The skill tells the lead to check the test runner's
  discovery roots when a repository's first run starts.
- Lanes are full checkouts. `--sparse` is for very large monorepos only, and
  the guide says so (ruling 13).
- `workloop.py widen <run> <lane> [--path <p>]... [--also <dir>]...` widens a
  running lane's owned paths, or its sparse set, refused only where another
  lane or a shared file owns the path.

### 7. Frictions

- **The brief is a dispatch line.** `brief` writes the full brief to
  `<worktree>/.workloop/BRIEF.md` (a read-only cell's to the run's folder) and
  prints a short dispatch prompt holding the header line and that path, which
  the lead pastes unchanged; the gate keeps reading the header.
- **Dead cells stop counting.** First find how each death shows in Claude
  Code's hooks (a stopped task, a usage limit, a crash, the session ending);
  then clear the record on each.
- **A marked cell is found at its first tool call**, not only its first file
  write, and a long turn's record of writer types stops granting registration
  to cells dispatched after those writers stopped. Seen in this session: a
  `WORKSPACE` benchmark cell registered as a writer because two earlier writers
  of its type had run in the same, hours-long turn. The widened matcher checks
  the live list in shell first, so only a cell still on it pays for Python.
- **A review may cite any existing file**, not only one in the repository.
- **Every run's composed test runs**: `check` runs it in the main checkout for
  a main-tree lane and requires a passing `integrate` for worktree lanes.
- **The digest names QA and `check`** when a run is ready for them.
- **Provisioning stops walking dependency folders.** `provision.sh`'s lockfile
  search (`nested()`) filters `node_modules`, `.venv`, `target` and `vendor`
  after descending into them; it runs again after every install to hash the
  lockfiles, and took 3.5 s of a `food-app-core` lane's 6 s (the install took
  1 s). Pruning them cuts every lane and every `EnterWorktree` session.
- **`--sparse` provisions what the install needs or refuses.** Today a bare
  sparse lane fails on `food-app-core` (its `patchedDependencies` folder is
  outside the cone) and succeeds wrongly on `claims-app` (npm workspaces
  outside the cone are silently not installed). `add-lane --sparse` adds the
  patch folders and every workspace member to the cone, and refuses when the
  cone drops a lockfile.

### 8. Stale worktrees

Lanes inside the checkout are not cleared by the system the way `/private/tmp`
was, so the controller removes its own stale worktrees (ruling 19).

- **Finished lanes.** A lane worktree whose lane is reviewed, integrated or
  torn down, or whose run or lane no longer exists in the run state, is
  removed when nothing in it is unsaved: no uncommitted or untracked files, and
  its tip reachable from a branch. Its branch is deleted once merged and kept
  otherwise; its labelled containers go by the existing ownership rule.
- **Abandoned lanes.** A run with no lane activity for 7 days is abandoned.
  Each of its worktrees that holds unsaved work is first committed, untracked
  files included and ignored files not, to `workloop/<run>/<lane>-saved`; then
  the worktree is removed and the lead's digest names the saved branch until
  someone deletes it. A run held for the operator's hand merge, such as
  `lq-ui`, loses only its folder after 7 idle days: its branch stays.
- **Runs with nothing left.** A run whose worktrees are all gone and whose
  lanes are all finished or saved is closed. Today that closes `fold` and
  `register-rewrite`, whose worktrees were removed by hand.
- **When.** `workloop.py prune [--dry-run]` does all of it and runs
  `git worktree prune` for entries whose folders vanished; the lead's
  session-start digest runs it, which costs one state read and one
  `git status` per recorded worktree. It touches only worktrees the run state
  records or that lie under `.agents/worktrees/`, never Claude Code's own
  `.claude/worktrees/`.

## Units and order

Gall's law: each unit works end to end before the next starts, and each lands
its commands together with the sentences that teach them, so no committed
text names a command the controller refuses. The language comes first because
it is the operator's main lever, but unit 1 carries only what today's
controller honours.

1. The shape guide: the six questions, the shapes with their costs and
   defaults, the brief fields, in the skill, `delegation.md` and the root
   light touch (D3); `lint-contract.py` warns above 24,000 bytes instead of
   failing (D2).
2. Provisioning: the pruned lockfile walk, and `--sparse` that provisions what
   the install needs or refuses.
3. Lane worktrees inside the checkout, the gate's nearest-working-tree rule,
   the hook lookup, `widen`, and stale-worktree cleanup (`prune`).
4. Frictions in the gate: dead cells, marker at first tool call, long turns.
5. The main-tree lane and the one-command one-writer run, every run's composed
   test, the brief as a dispatch line, review references, the digest.
6. Read-only cells in runs (`add-cell`, `returned`, `check`).
7. Shared files (`share`, `--rebuild`).
8. Contracts (`--contract`, `ack-contract`, `built_on`, `--provisional`).
9. Outside projects (the baseline refusal).

`workloop.py` is 965 lines; unit 5 splits run bookkeeping from Git
operations before adding commands to it.

## QA claims

- Headline, run in three fresh Claude sessions and one Codex session, all of
  which must pass: a session given an objective shaped like `lq-ui`
  (two areas joined by an interface, shared `pyproject.toml`, `uv.lock` and
  `README.md`, a project outside the repository) chooses a contract-first
  split from the guide alone, and runs it end to end: the contract committed,
  the consumer building while the producer is reviewed, `uv.lock` rebuilt at
  `integrate`, a read-only reviewer recorded and returned, the composed test
  passing, the worktrees under `.agents/worktrees/`, nothing under `/tmp`, and
  no hand edit of run or gate state.
- Per unit: its tests fail against the code before it and pass after; the gate
  units add a live check in a Claude session with real cells.
- Cleanup: a test per case — a finished clean lane removed, an abandoned
  dirty lane saved to its branch then removed, a run with nothing left closed,
  a busy lane and `.claude/worktrees/` untouched.
- Unverified by design: a cell dying from a usage limit cannot be caused on
  demand; the report names it.

## Decisions walked (2026-10-13)

- **D1. Sparse lanes by default.** Benchmarked on this machine (M1 Pro, warm
  caches), three lanes each on this repository, `claims-app` and
  `food-app-core`: sparse saved 0.07–0.85 s and 100–215 MB per lane, left the
  install unchanged or got it wrong, and tests needed one to four folders
  added by hand. **Ruled:** sparse for very large monorepos only; lanes are
  full checkouts by default, and unit 2's provisioning fixes stand.
- **D2. The root contract's size.** No published figure for where Opus 5.5 or
  Fable 5.1 stop following an instruction file; Codex silently stops reading
  AGENTS.md text at 32 KiB, counted from the root down to its working folder.
  **Ruled:** no hard limit; `lint-contract.py` warns above 24,000 bytes and
  passes. Consequence: past about 22,500 root bytes, Codex working inside
  `.agents/skills/market-researcher/` (5,666 + 4,591 nested bytes) loses the
  end of the deepest file; the warning text names Codex's cut.
- **D3. The root light touch.** **Ruled:** approved as drafted. It replaces the
  root's sentence on concurrent writers (184 bytes) with: "Choose the shape
  first, by the workloop skill's guide: one writer by default, read-only cells
  around it. A multi-cell delegation is one `workloop` run: writers working at
  once get a worktree each, and the merged result is verified once." It lands
  with unit 1.
- **D4. Tier follows difficulty, not stakes.** The root sends "complex or
  critical work" to frontier, and this spec's review went to fable while the
  gate's reviews at the same stakes went to opus. **Ruled:** left as it is; the
  root and `hostile-review.md` keep their wording, and the lead picks each
  cell's tier.

## Review dispositions (round 1, 2026-10-13)

Fourteen findings against r1; thirteen adopted into this text, one superseded by a ruling.

| # | Finding | Disposition |
|---|---|---|
| 1 | P1: a lone main-tree lane still paid for an integration worktree | Adopted: `check` verifies it in the main checkout; one-command one-writer run (§2) |
| 2 | P1: `init` pinned the base before the contract was committed | Adopted: commit, then `init`; `--contract` refuses a path absent at the base (§5) |
| 3 | P1: rebuild commands ran unguarded at `integrate` | Adopted: guarded when declared (§4) |
| 4 | P1: unit 1 taught commands that did not exist yet | Adopted: each unit lands its commands with their text (Units) |
| 5 | P2: the root sentence leaves zero bytes of headroom | Superseded: the limit became a warning at 24,000 (D2) |
| 6 | P2: a main-tree lane recorded `main` as its branch | Adopted: no branch, no worktree, a commit range (§2) |
| 7 | P2: a dead read-only cell blocked `check` forever | Adopted: `returned --failed` (§2) |
| 8 | P2: nothing observed a producer's branch moving | Adopted: the digest compares `built_on` (§5) |
| 9 | P2: rebuild paths would conflict at merge; order unstated | Adopted: merge order stated; `share` refuses an owned path (§4) |
| 10 | P2: a widened gate matcher costs every tool call | Adopted: shell check first (§7) |
| 11 | P2: a `.git` file also marks a submodule; two nested conventions | Adopted: `git rev-parse --show-toplevel`; special cases listed (§6) |
| 12 | P2: the skill would pass 500 lines; the brief had two owners | Adopted: examples in reference files; the controller owns the brief (§1) |
| 13 | P2: a one-run QA claim, Codex uncovered | Adopted: three Claude sessions plus one Codex (QA) |
| 14 | P2: only bake-offs were priced; no tier question | Adopted: a cost line per shape and a sixth question (§1) |

## Out of scope

- Controller support for bake-offs (ruling 10).
- Whether to keep the unused `panspermia-mutation` skill: a separate call.
- The `lq-ui` run (ruling 7).

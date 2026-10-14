# Workloop: the lead designs the delegation

Spec, critical stakes (it changes the parallel-writers, teardown and wait
gates, the workloop controller, the personas, and contract text). Rulings came
from the operator on 2026-10-13; none is open. No build starts before the
operator's OK on this spec.

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

Later the same day:

> I've noticed subagents take years running stupid commands, tests, builds and
> who knows what. Any idea what's up with that

and, on the findings below, "fold this in" and "add this to the test write up
as well".

So the language the lead reads (the shape guide, the briefs, the refusals) is
the main deliverable; controller changes serve it, and hold only what language
alone cannot. The same holds for what a cell reads: its persona and its brief
decide how it spends its time.

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

### Where cells' time goes (the 14 days to 2026-10-13)

A scratch scan of the Claude Code session store (both accounts share it):
890 cells whose transcript changed in the window, so a cell that began before
it counts whole. The figures are pattern matches, close enough to rank the
causes; unit 1's `cell-time.py` recomputes them with the definitions in §9,
and the QA compares against that rerun, not these numbers.

The rerun (2026-10-14, commit a7a965d, records 2026-09-30 to 2026-10-14,
921 cells): 613 blind waits ran under the cell's rules (16h42m of
execution); 27 Bash calls past 600 s and 155 past their own timeout; 44
windows of store-wide silence, 179h52m in all, removed from every delay;
566 shell writes to tracked source files against 2,448 Edit and Write
calls, so the pattern above overstated shell writes about tenfold; tests
11h40m and builds 1h08m of execution.

- 404 hours from each cell's first record to its last. 207 of them are gaps
  over 30 minutes: 131 hours parked until the lead messaged the cell again,
  and 48 hours before a model response, cause not established. The rest
  splits about 128 hours model and 99 hours tools; records are not in time
  order, so the parts overlap and sum past the span.
- 61 hours in shell commands. Commands matching a test pattern took 16.2
  hours (5,136 calls; the pattern also catches reading a test file). Commands
  matching a build, install or Docker pattern took 12.7 hours (878 calls, 52 s
  each on average). No cell ran a byte-identical test command four times, but
  reruns vary their arguments: one `claims-app` cell ran pytest 52 times. A
  run of one to three tests took 9–16 s, mostly the fixed start of a Postgres
  container; six runs took the broad suite (1,484 to 6,376 tests, 29–382 s
  each) while the cell was still fixing.
- Two Bash calls had their result recorded hours after the call: a QA cell's
  dev-server start 10.4 hours, an implementer's `bun run verify` 6 hours.
  Bash's ceiling is 10 minutes. Whether these ran that long, waited on a
  permission prompt, or sat in an interrupted turn is not established.
- Blind waits: replayed through `wait-gate.py`, 558 cell commands would have
  been refused, 15.9 hours of their time: long sleeps, 67 sleeps polling a
  background task's output file, and bare `&` backgrounds, most of them
  servers. The gate never saw them: it is registered `--agent main`, so it
  runs for the lead only (since it landed, 2026-09-27, with no recorded
  reason). Its remedy, "end your turn and you are notified", does not fit a
  cell, whose ended turn returns it to the lead.
- Shell commands matching a file-write pattern (`python3 - <<EOF`, `sed -i`,
  `cat >`): 5,384, against 2,408 Edit and Write calls. The pattern also
  catches read-only Python heredocs and scratch files, so it overstates source
  edits by an unknown share. A source file written from the shell costs a
  model turn writing a script, and the post-edit hooks never see it. 152 Edit
  or Write calls failed with "File has not been read yet".
- Today's guidance: the workloop brief says "run only the narrowest acceptance
  for your slice"; `implementer` says the same; `qa-verifier` says to stop what
  it backgrounded. None says how to iterate on a failing test, how to start a
  server, how a cell waits, or how to edit a file.

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
| 19 | Worktrees left behind | None outlasts the session that made it: the teardown gate records it, the session end removes it, unsaved work is committed to a saved branch first | `worktrees-end-with-their-session` |
| 20 | Worktrees already left behind | Healed by the scaffold once transplanted: unrecorded, unlocked and idle 24 hours, they are saved and removed | `worktrees-end-with-their-session` |
| 21 | Where cells' time goes | Addressed in this redesign and measured in its QA; a gate on shell file writes waits on that measure | this spec |

## Design

### 1. The shape guide (the language)

The lead designs each delegation before dispatching it, by answering six
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
- Root `AGENTS.md`, Delegation paragraph, a light touch (ruling 17): two
  sentences naming the guide and the default shape, for every host.
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
  rebuilt lockfile, and runs the composed test. `uv lock` from the base's
  lockfile keeps the base's versions; `npm install --package-lock-only`,
  `pnpm install` and `bun install` re-lock likewise.
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
  `send`'s `--supervised` requirement. The controller refuses the consumer's
  `submit`, an accepting `review`, and `integrate` until the producer is `reviewed` and `built_on`
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

### 8. A worktree ends with the session that made it

The operator expects no worktree to outlast the session that made it (ruling
19). Practice says otherwise: on 2026-10-13, seven repositories under
`~/Projects` held 54 worktrees beyond their main checkouts (22 in
`tax-appeals-engine`, 12 in `claims-app`, about 15 GB in `claims-app`
alone), almost all with nothing uncommitted. The teardown gate already makes
agents stop the containers, servers and browsers they start; worktrees join
it as one more resource class.

- **Recorded when made.** `teardown-gate.sh` records a worktree as the
  session's resource when an agent tool call makes one: `git worktree add` in
  Bash, Claude Code's `EnterWorktree`, an `Agent` cell with
  `isolation: "worktree"` that Claude Code kept, and `workloop.py add-lane`.
- **Due at completion.** Like a container, a worktree is due once a
  `git push` runs after it was made, and before that is listed as "remove
  before the session ends". The block names `git worktree remove <path>` or
  `workloop.py teardown <run>`.
- **Removed at the session's end.** A session-end hook removes every worktree
  the session recorded that is still on disk: one with nothing unsaved goes at
  once, its branch deleted when merged and kept otherwise; one holding unsaved
  work is first committed, untracked files included and ignored files not, to
  `saved/<worktree-name>`, then removed. The next session's start digest names
  each saved branch until someone deletes it.
- **Sessions that never ended cleanly.** A crash, a killed terminal, or a host
  with no session-end event leaves its record behind. The session-start hook
  sweeps the records of sessions no longer running and treats them the same
  way, so Codex and Kimi lanes are covered too.
- **Healing what predates the scaffold.** The operator expects a transplant
  to clear the worktrees older sessions left (ruling 20), so the session-start
  sweep also takes each worktree of the repository that no record names, is
  not locked, and has been idle 24 hours (no commit, checkout or file change):
  saved and removed like any other. Idle time, not a running process, decides,
  because Claude Code resets a shell's folder to the checkout and a session
  working in a sibling worktree by absolute paths shows no process there.
  `git worktree lock <path>` is how anyone keeps one, such as
  `writing-app-export`; the sweep never touches a locked worktree.
- **Workloop runs.** A run's lanes belong to the lead session that added them,
  so a run does not outlive its lead either: the session end saves and removes
  its worktrees and closes the run. A run whose worktrees are already gone,
  as `fold` and `register-rewrite` are today, is closed by the same sweep.
- **Unit 5 probes first** that Claude Code's `SessionEnd` hook fires on
  `/exit`, a closed terminal and a resumed session, and how long it may run:
  removing a lane with `node_modules` took 4–5 s in the benchmark.

### 9. Cells spend their time on the work

Ruling 21. Language carries most of it, as for the lead; the wait gate is the
one gate, because it exists and only its scope is wrong.

- **How a cell works.** The brief the controller writes gains a
  working-practice block; `implementer` and `qa-verifier` say the same in both
  hosts' persona files (`.agents/personas/*.md` for Claude Code,
  `.codex/agents/*.toml` for Codex); `delegation.md` tells the lead to put the
  block in a generic cell's prompt, which reads no rule file of its own. Each
  host's text uses that host's tools:
  - Run the brief's acceptance, iterating on the narrowest test that covers
    the failure: one test, file or package. In a run, nothing broader: the
    composed test runs once over the merged tree, at `integrate` or `check`
    (§2). Outside a run, a full suite runs only when the brief names it, once,
    before returning. When one acceptance run costs over a minute, the result
    says so, and the lead weighs that against its next dispatch.
  - Start a server, a watcher, or anything else that does not exit, where the
    host can see and stop it. Claude Code: `run_in_background: true`. Codex,
    which has no background flag:
    `nohup sh -c '<cmd>; echo "exit=$?"' > <log> 2>&1 & echo $!`, keeping the
    process number. Wait for it with a capped loop
    (`for i in $(seq 60); do curl -sf <url> >/dev/null && break; sleep 2; done`;
    macOS has no `timeout` command), and stop it before returning: `TaskStop`
    in Claude Code, `kill` on its process number in Codex. Never in the
    foreground.
  - A writing cell edits a file with its host's edit tool: Read, then Edit
    or Write in Claude Code; `apply_patch` in Codex. A shell script writes
    only the output a command generates; a source file written from the shell
    skips the post-edit hooks. `qa-verifier` writes no file and keeps its
    tools.
- **The wait gate covers cells, in Claude Code** (Codex has no background
  flag, and the gate stays unwired there, as `.agents/README.md` says).
  `normalize-hook.py` passes the payload's `agent_id` to `wait-gate.sh`, which
  loses `--agent main` and picks its remedy by it: the lead keeps today's
  text. A cell is told:
  - A command that ends within 10 minutes runs in the foreground, with Bash's
    `timeout` set to cover it (the default is 2 minutes; the ceiling is
    600000 ms).
  - A longer command starts with `run_in_background: true` and writes its own
    end marker (`<cmd>; echo "exit=$?"`). The cell keeps working: probed
    2026-10-14, a cell is told a background call ended with its next tool
    result, without ending its turn. With nothing left to do, it waits in
    calls of at most 10 minutes, each a capped loop on that marker
    (`for i in $(seq 110); do grep -q '^exit=' <output> && break; sleep 5; done`
    with Bash's `timeout` at 600000), repeated until it shows. Bash's own
    timeout caps every call at 10 minutes, so for a cell the gate lets a poll
    on a task's output file pass when no sleep in it is longer than 5 s;
    every other refusal stands.
  - The lead's remedy loses `timeout 120 bash -c …` for the same capped loop:
    macOS has no `timeout` command (found 2026-10-14).
  - `TaskStop` works in a cell (probed): `implementer` and `qa-verifier` carry
    it. A background call outlives the cell that started it (probed), so
    stopping what it started is the cell's job.
  - `.agents/README.md`'s description of the gate changes to match, and
    `cell-time.py` replays a cell's commands under the cell's rules.
- **Results recorded hours after the call** (classified 2026-10-14). Neither
  ran past the ceiling. The 10.4-hour one waited on the `browser_close` call
  issued with it, most likely a permission prompt while the operator was away
  (by elimination: transcripts do not log prompts). The 6-hour one was the Mac
  asleep: every session in the store fell silent in the same second and woke
  together, and the call's 600 s timer fired at wake. `cell-time.py`
  therefore subtracts windows in which the whole store is silent from every
  delay, and counts the rest as execution only when no other call of the same
  assistant message was still pending.
- **No gate on shell file writes yet.** A gate cannot tell a script that
  edits a source file from one that generates output by reading the command
  alone, so the language goes first and QA measures it. A rate still above
  one shell source write per Edit or Write call is filed as the next unit.
  The rerun baseline is 566 against 2,448, already below that line, so the
  gate waits on the rate rising, not falling.
- **The measure is committed.** `.agents/eval/cell-time.py` reads Claude
  Code's session store, selecting records by their own timestamps within a
  period and cells by their working folder's repository, and prints per cell
  and in total:
  - active and idle time;
  - shell time by kind;
  - execution time of the longest commands;
  - blind waits that ran, replayed through `wait-gate.py`, beside the gate's
    refusals;
  - shell source writes (a write pattern naming a tracked file of the
    working folder's repository) against Edit and Write calls;
  - runs of the brief's composed test (the run's `--verify` string) inside
    lanes.

  It writes nothing and reads each transcript once; the scratch scan took
  about two minutes over the 890 cells above. Codex cells are outside it,
  and the report says so. The baseline and the QA run the same code.

## Units and order

Gall's law: each unit works end to end before the next starts, and each lands
its commands together with the sentences that teach them, so no committed
text names a command the controller refuses. The language comes first because
it is the operator's main lever, but unit 1 carries only what today's
controller honours.

1. The shape guide: the six questions, the shapes with their costs and
   defaults, the brief fields, in the skill, `delegation.md` and the root
   light touch (D3); `lint-contract.py` warns above 24,000 bytes instead of
   failing (D2). The working-practice block in the brief and in both hosts'
   `implementer` and `qa-verifier`, its line in `delegation.md`, and
   `cell-time.py` with the baseline rerun from it (§9).
2. Cells' waits (§9; probes done 2026-10-14): the wait gate for cells with
   its remedy, the lead's remedy without `timeout`, and `cell-time.py`'s
   cell rules and silent-store windows.
3. Provisioning: the pruned lockfile walk, and `--sparse` that provisions what
   the install needs or refuses.
4. Lane worktrees inside the checkout, the gate's nearest-working-tree rule,
   the hook lookup, `widen`.
5. Frictions in the gate: dead cells, marker at first tool call, long turns;
   worktrees in the teardown gate, removed at the session's end (§8).
6. The main-tree lane and the one-command one-writer run, every run's composed
   test, the brief as a dispatch line, review references, the digest.
7. Read-only cells in runs (`add-cell`, `returned`, `check`), and D3's
   second sentence in the root.
8. Shared files (`share`, `--rebuild`).
9. Contracts (`--contract`, `ack-contract`, `built_on`, `--provisional`).
10. Outside projects (the baseline refusal).

`workloop.py` is 965 lines; unit 6 splits run bookkeeping from Git
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
- Worktrees: a test per case — made by `git worktree add`, `EnterWorktree`
  and `add-lane` and recorded; a clean one removed at session end; a dirty one
  saved to its branch, then removed; a dead session's swept at the next start;
  an unrecorded one idle 24 hours saved and removed; a locked one and one active today untouched.
- Cells' time (§9), in two parts:
  - In the three Claude headline sessions, every cell, by `cell-time.py`: no
    blind wait runs; no command's execution time passes its Bash timeout; no
    lane runs the composed test (the run's `--verify` string), which runs once
    per `integrate`. Servers by process state: the QA lists the listening
    ports and the processes under the session before each cell's dispatch and
    after its return, and nothing new survives the return unless the cell
    names it under STILL UP. The Codex session is checked by hand against
    the same claims, and the report says so.
  - Over the 14 days after units 1 and 2 land, `cell-time.py` compares Claude
    cells in the repositories carrying them with the same repositories over
    the 14 days before, as rates per cell: blind waits that ran and the
    gate's refusals, Bash calls over 10 minutes of execution, and shell source
    writes per Edit or Write call. Blind waits that ran must fall to none,
    since the gate now refuses them; the other figures are reported beside
    their baseline, with test and build hours per cell, and no target,
    because their counts are small and the mix of work moves them. A rate of
    shell source writes still above one per Edit or Write call files the
    shell-write gate (§9). This part reports when the period ends and holds
    none of the other claims.
- Wait gate: a test per case — a cell's long sleep and bare `&` refused with
  the cell's remedy, the lead's with today's; a cell's capped loop on an end
  marker passing, also on a task's output file; the same loop sleeping over
  5 s refused; a lead's poll on a task's output refused as today; no remedy
  text names `timeout`.
- Unverified by design: a cell dying from a usage limit cannot be caused on
  demand; the report names it.

## Decisions walked (2026-10-13)

- **D1. Sparse lanes by default.** Benchmarked on this machine (M1 Pro, warm
  caches), three lanes each on this repository, `claims-app` and
  `food-app-core`: sparse saved 0.07–0.85 s and 100–215 MB per lane, left the
  install unchanged or got it wrong, and tests needed one to four folders
  added by hand. **Ruled:** sparse for very large monorepos only; lanes are
  full checkouts by default, and unit 3's provisioning fixes stand.
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
  with unit 1. **Re-ruled 2026-10-14:** its second sentence lands with unit 7,
  once the controller records read-only cells and runs a lone writer in the
  main tree. Until then the root says what today's controller honours:
  "Writers working at once go through one `workloop` run: a worktree each, and
  the merged result is verified once."
- **D4. Tier follows difficulty, not stakes.** The root sends "complex or
  critical work" to frontier, and this spec's review went to fable while the
  gate's reviews at the same stakes went to opus. **Ruled:** left as it is; the
  root and `hostile-review.md` keep their wording, and the lead picks each
  cell's tier.

## Review dispositions (round 1, 2026-10-13)

Fourteen findings against r1; thirteen adopted into this text, one
superseded by a ruling.

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

## Review dispositions (round 2, 2026-10-13)

Eight findings against the cells'-time amendment (ruling 21, §9); all adopted,
one in part.

| # | Finding | Disposition |
|---|---|---|
| 1 | P1: "run the composed test before returning" contradicted "verified once" | Adopted: lanes run the brief's acceptance; the composed test stays with `integrate` and `check` (§9, QA) |
| 2 | P1: Claude-only tool names in text Codex cells read; `qa-verifier` told to edit | Adopted: each host's text uses its tools; Codex persona files named; Codex checked by hand (§9, QA) |
| 3 | P1: "ran 10.4 hours" was a recorded gap, which permission waits also make | Adopted: evidence restated; unit 2 classifies first; execution time measured without non-execution classes (§9, QA) |
| 4 | P1: no permitted wait for a cell's command over 10 minutes; `agent_id` not passed | Adopted: an end marker and a capped poll; normalizer and README listed; tests per case (§9, QA) |
| 5 | P1: QA claims unmeasurable or measured on a shrinking population | Adopted: composed test by its `--verify` string, servers by process state, rates per cell over the same repositories, rerun baseline (QA) |
| 6 | P2: the shell-write count includes read-only heredocs | Adopted: relabelled; `cell-time.py` counts writes naming a tracked file (Evidence, §9) |
| 7 | P2: figures mislabelled; overlapping time parts; "breadth, not repetition" | Adopted in part: relabelled as pattern matches and the line dropped. The 152 are confirmed: the scan grouped failures by message, and all 152 read "File has not been read yet" |
| 8 | P2: unit 4 carried three pieces of work | Adopted: the waits are unit 2; ruling 21 reworded (Units) |

## Out of scope

- Controller support for bake-offs (ruling 10).
- Whether to keep the unused `panspermia-mutation` skill: a separate call.
- The `lq-ui` run (ruling 7).

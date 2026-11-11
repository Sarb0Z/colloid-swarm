# Harness build-out: six units, planned

Workflow: Scaffold · Stakes: Critical (the root contract, the playbooks, the
reviewer contract, and the `session-wrap`, `post-edit-check` and
`guard-publish` hooks).

**Gate: passed.** The operator OK'd this plan on 2026-11-11, all four waves,
with the four rulings below. The grilling step was folded into those rulings,
because the operator ruled on the design across the session that produced
this plan (`.agents/decisions.md`: `review-at-delivery-boundaries`,
`chunks-sized-to-one-agent-run`, `delegation-strategy-changeable-midway`,
`outward-approvals-not-batched`).

The ask, verbatim (2026-11-11): "okay, let's build out 1,2,4,7,5,9 — as i
understand, 7 really applies at the transplant level since we won't know what
the vendors are for a repo". The numbers are the ideas in
`.agents/knowledge/research/2026-11-11-fleet-session-logs-mined-for-harness-ideas.md`,
as revised in the session: 1 research before the plan, 2 verification by
execution, 4 owed-work flags in place of the session-wrap question, 5
background work that reports progress, 7 read access to each product's
systems, 9 lint and type checks that cannot go silently missing.

The plan was reviewed once at `7d10c5c` (run `harness-build-plan-review`, one
reviewer on opus): 9 `P1` and 17 `P2` findings, every one dispositioned under
"Review" below. This text is the plan after those dispositions.

## Findings the plan rests on

Read at `c31b533` by six read-only cells (run `harness-build-research`), the
lead and the plan's reviewer. Status is `observed` (the line was opened, or
the probe was run) or `inferred`.

| # | Claim | Evidence | Status |
|---|---|---|---|
| F1 | A plan has no committed path or schema, and no hook reads one; the only mandated structure is the Plan row and its `Lenses:` block | `AGENTS.md:46`; `rg plan .agents/hooks` | observed |
| F2 | The reviewer contract is the fenced block of `hostile-review.md`; `test-review-contract.sh` fails when it differs from `eval/review-harness/contract.md`, and `extract-contract.sh` regenerates that copy and requires a fixed list of strings | `hostile-review.md:17-82`; `eval/review-harness/bin/extract-contract.sh:23-60` | observed |
| F3 | The root contract is 21,163 bytes against a 24,000-byte warning | `lint-contract.py:18`; `wc -c AGENTS.md` | observed |
| F4 | `explorer` is pinned to haiku, has no shell, and returns `CONCLUSION / EVIDENCE / GAPS`, with no commit and no status per claim; a research cell's brief carries only the role line "find and ground the facts the objective needs, each with its source and date" | `personas/explorer.md:4-23`; `workloop_cells.py:21` | observed |
| F5 | The reviewer persona says "Do not edit, test, or delegate" while granting a shell; the Critical review of the review labels findings supported or unsupported and runs nothing | `personas/reviewer.md:12`; `hostile-review.md:116-124` | observed |
| F6 | QA receives "the ask, plan, changed paths, runnable commands" and derives its scenarios afterwards; nothing stores expected behaviour before the code | `skills/qa-verifier/SKILL.md:14-20` | observed |
| F7 | The root Build table puts QA before code review; the controller refuses `qa` until every lane is `reviewed`, stores one QA record per run with no tip, and `check` asks only that the record exists | `AGENTS.md:51-52`; `workloop_finish.py:45-53`; `workloop_main.py:292-293` | observed |
| F8 | `session-wrap.sh` has one blocking exit, fed by three messages that tell the agent to ask the operator, and by the work-log reminder; it cannot see the answer, so a skip is recorded only as "asked". It also runs on Codex and Kimi | `session-wrap.sh:504-551, 557-618, 641-643`; `.codex/hooks.json`; `.kimi/config.toml.example:166` | observed |
| F9 | `edit-record.sh` already records, per session, the paths its editors wrote and the commits it made, merge commits included | `edit-record.sh:5-26, 105-154` | observed |
| F10 | A review is recorded as prose in `docs/reviews/*.md` with no machine-readable commit range, and as `accepted_tip` in the gitignored run state, which is absent outside a run. No contract line requires the file; the playbook says "create no parallel review ledger" | `docs/reviews/2026-11-11-scrapling-u2.md:1-20`; `workloop_lanes.py:137-166`; `hostile-review.md:91-92` | observed |
| F11 | Nothing records that the full suite ran on a commit; the carrier has no single suite command, only the list in `.agents/AGENTS.md` and `ci.yml` | `rg` of hooks and tests; `.agents/AGENTS.md:73-122`; `.github/workflows/ci.yml:36-91` | observed |
| F12 | A hook's JSON output may carry `systemMessage`, "Warning message shown to the user" | code.claude.com/docs/en/hooks, read 2026-11-11 | observed |
| F13 | A Stop hook that exits 0 with `systemMessage` shows the line without continuing the turn: headless, one `system` event of level `notice` reading "Stop says: <line>" and the turn ended with `end_turn`; in an interactive terminal, the line drew under the reply as `⎿  Stop says: <line>` and the prompt returned with no further turn | probes run 2026-11-11 and 2026-11-12 on 2.1.322: `claude -p … --output-format stream-json --verbose`, and an interactive session in a detached tmux pane read with `capture-pane`, each in a scratch folder with one Stop hook | observed |
| F14 | `guard-publish` already answers every `git push`: `ask` in default mode and `deny` in auto mode. It receives the command, `cwd` and `permission_mode`, and does not resolve which commits a push carries | `hooks/lib/guard-publish.py:502-510, 941-964`; both modes fed on stdin 2026-11-11 | observed |
| F15 | A lane stores `heartbeat_at` and a `progress` string, with no stated cadence; a cell stores only `out_since` and `returned_at`; `status` prints no ages. `watch` already lists lanes whose heartbeat is older than a threshold | `workloop_lanes.py:248-259`; `workloop_cells.py:71-119, 54-59`; `workloop_messages.py:83-87` | observed |
| F16 | A lane's brief opens `WORKLOOP <ROLE> BRIEF — <run>/<lane>`; a cell's prompt carries `WORKLOOP CELL BRIEF — <run>/<name>` on its second line, after `READ-ONLY`. The controller reads no transcript. The inbox hook runs between a subagent's tool calls and is handed four fields only: `project_dir`, `event`, `session_id`, `agent_id`; it binds an agent to a lane by the lane's claim and has no binding for a cell | `workloop_lanes.py:316`; `workloop_cells.py:152`; `workloop-inbox.sh:9-26, 37-64`; `rg 'transcript' .agents/workloop*.py` (no match) | observed |
| F17 | A hook cannot wake an idle lead; the workloop skill already tells a lead whose run outlives its turn to schedule `/loop 10m .agents/workloop.py watch <run>` | `workloop-inbox.sh:22-24`; `skills/workloop/SKILL.md:372-379` | observed |
| F18 | The status line reads the host's JSON and git only; its test fixture copies two files | `claude/statusline.sh:44-68`; `test-statusline.sh:17-18` | observed |
| F19 | The transplant procedure already has a per-repository adaptation step that records "access snapshot, credential path" by hand in the gitignored `CLAUDE.local.md`; the tax-appeals-app repositories hold a hand-written list of probes such as `vercel whoami` | `export/README.md:215-220`; `tax-appeals-web/CLAUDE.local.md:10-20` | observed |
| F20 | `guard-publish` has write-verb rows for vercel, netlify, wrangler, firebase, fly, railway, supabase, terraform, gcloud, aws and gh, and none for the Stripe or Sentry command lines; no satellite is shown to use either | `hooks/lib/guard-publish.py:57-90, 163-226`; grep | observed |
| F21 | `post-edit-check.sh` skips a checker whose binary it cannot find and prints nothing, for ruff, eslint, prettier, tsc, pyright and the Dart analyzer. It keeps tsc output only on lines that name an edited file, and it discards pyright's stderr and reads an empty result as clean | `post-edit-check.sh:194-203, 241-281, 345-443`; `hooks/lib/js-groups.py:46-65` | observed |
| F22 | In a tree whose `node_modules` is a symlink to another tree, `js-groups.py` given that tree as the project returns no group, so ESLint and Prettier never run in a Codex or Kimi lane, whose payload names the worktree; Claude's adapter names the main checkout, where the link already resolved (unit 9 review, finding 14); `worktree-provision` shares `node_modules` by symlink by default | probe run twice 2026-11-11, by the lead and by the reviewer (0 groups linked, 1 group copied); `worktree-provision.sh:32, 65-73` | observed |
| F23 | The "eslint … Nothing was linted" message does block (exit 2); its 1,056 logged lines are 1,052 from claims-app in 2026-09 and 4 from delivery-web, and ESLint runs clean in both today | `post-edit-check.sh:331-333, 475-483`; log count and two runs, 2026-11-11 | observed |
| F24 | `test-post-edit-check.sh` pins the Dart paths, one ESLint working-directory case and the path guards; nothing pins ruff, tsc, pyright or a checker that cannot run | `test-post-edit-check.sh:49-166` | observed |
| F25 | A Stop hook's input lists `background_tasks` and `session_crons`, so a hook can tell a session that is done from one waiting on background work; both were empty arrays in the probe | code.claude.com/docs/en/hooks, Stop input, read 2026-11-11; the F13 probe's captured input | observed |
| F26 | The root contract, the Merge playbook and the review playbook still require several axis reviewers at Critical; the decision `review-at-delivery-boundaries` is recorded and not yet landed in them | `AGENTS.md:52`; `playbooks/workflow-merge.md:11`; `hostile-review.md:110-113` | observed |
| F27 | A run's folder is gitignored and its briefs are deleted at teardown; `provision.sh` installs a worktree's dependencies and the provisioning hook runs it only when a subagent starts | `.gitignore:27`; `workloop_finish.py:246-252`; `worktree-provision.sh:43-57` | observed |
| F28 | The adapter hands the inbox hook `project_dir`, `event`, `session_id` and `agent_id`, not `transcript_path`, which it passes to other hooks; a subagent's transcript is `agent-<agent_id>.jsonl` in the session's `subagents/` folder beside the `.meta.json` the writers gate reads; in four of this session's subagent transcripts the first record carries the brief header, on line 1 for a lane and on line 2 after `READ-ONLY` for a cell | `claude/normalize-hook.py:84-99`; `hooks/lib/cell_markers.py:13-18, 100, 196`; four transcripts read 2026-11-12 | observed |
| F29 | The subagent's `.jsonl` exists, holding that first record, when the inbox hook first fires between its tool calls | `cell_markers.py` notes its metadata is written after `SubagentStart` | inferred |

## One reader for four readouts

Units 4, 5, 7 and 9 each replace a question or a silence with a readout
computed from state: what is owed, what is running, what is reachable, which
checks are active. Chunk 0.2 builds the shared part once: a gitignored
runtime folder, `.agents/.readout/`, holding one small file per unit (a line
for the status strip, a section for the session-start note, the time it was
written) and each unit's once-per-session ledgers; one reader that
`statusline.sh` and `session-start.sh` call; and one command that prints
every readout in full. A unit then writes its own file and touches neither
the strip nor the session-start script.

## Units

Each unit is one delivered scope: its chunks are sized for one agent run of
about 200k tokens, a chunk gets no reviewer, and the unit is reviewed and its
claim QA'd at its boundary. Every hook or gate change ships with a firing
test that fails without it. Acceptance below is the numbered claim QA
reproduces.

### Unit 0 — foundations

- 0.1 The review rule lands in the contract (F26): the Critical cell of the
  Build table's code-review row, the Merge playbook's row and the review
  playbook's wave paragraph say one cross-functional reviewer per delivered
  scope, and reviewers split by axis only when the work is also designed from
  first principles. Written by the lead. Pass condition, two fresh headless
  sessions each: asked for a small change on a critical path, the session
  names one reviewer; asked for an authentication design built from scratch,
  it names reviewers by axis.
- 0.2 The readout reader described above, with a test that a unit's file
  appears in the strip and in the session-start note, and that a file older
  than a day is shown with its age.

Acceptance: (1) both fresh-session conditions hold in two of two runs;
(2) a file written into `.agents/.readout/` shows in the status strip and
the session-start note with no edit to either script.

### Unit 9 — checks that cannot go silently missing

A repository that configures a checker has asked for it. The hook treats
"configured but could not run" and "ran but could not be read" as findings,
and "not configured" as silence.

- 9.1 `js-groups.py` accepts a `node_modules` that links to the main tree of
  the same repository (F22), with test rows for the linked and the foreign
  case. `post-edit-check.sh` reports a configured checker whose binary is
  missing, once per session and workspace, naming the install command: ruff
  (a section in `pyproject.toml`, or `ruff.toml`), ESLint (a flat config or a
  legacy `.eslintrc*`), Prettier, tsc (`tsconfig.json`), pyright and the Dart
  analyzer. The once-only ledger lives in the readout folder and is created
  atomically, because checks run concurrently in the background.
- 9.2 The unreadable run (F21): pyright's stderr is kept, and a tsc or
  pyright run that exits non-zero with no line the hook can parse is
  reported with its first line. Errors outside the edited files stay out of
  the per-edit report, with one exception for tsc: the hook keeps, per
  session and workspace, every error line it has seen, and a line outside the
  edited files that is not among them is reported, since that edit broke a
  caller. The first run in a session sets the baseline silently.
- 9.3 Firing tests for ruff in both modes, tsc, pyright, the ESLint
  no-report path and each case above (F24). The unit writes a readout naming
  the checkers missing in the repository.

Acceptance: (1) in a lane worktree with linked `node_modules`, an edit that
introduces an ESLint error is reported; (2) in a repository with a ruff
config and no ruff binary, the first edit names the missing checker and the
second is quiet; (3) an edit that changes a function's signature is reported
with the type error it causes in an unedited caller; (4) a broken
`tsconfig.json` is reported, not read as clean.

### Unit 7 — read access, declared at the transplant

Scope: systems a command line can read. Systems read only through a
signed-in browser, and test identities, are left out and filed as a
breadcrumb; the operator's reaction to the first version of this idea was
that it looked brittle, and the practice researched since favours vendor
command lines and official connectors.

- 7.1 `policy.json` gains `systems`: for each system the product runs on, its
  name, a probe command that exits 0 when reachable, its read commands, and
  a log command per environment (local, staging, production). The tracked
  file holds names and commands only; credential routes and account
  snapshots stay in the gitignored `CLAUDE.local.md`, as the transplant
  procedure has them (F19). `.agents/access.py probe` runs the probes with a
  short timeout and writes reachable or unreachable, the exit status and the
  time into its readout; a probe's output never enters the readout or the
  session-start note. Before running a declared command, `access.py` passes
  it through the publish guard's classifier and refuses one the guard would
  ask about, so a write declared as a read does not run unasked.
- 7.2 The probe runs when an agent or the operator runs it, never at session
  start; it writes a readout with `stale_after` of a day, so the session-start
  note shows the last table with its age once it is older. A repository never
  probed shows nothing: the transplant's Systems step (7.3) runs the first
  probe, and `stop-investigate.sh`, which already stops a turn that claims it
  cannot do something, names `access.py probe` in its message (review
  `2026-11-11-harness-u0` finding 1).
- 7.3 `export/README.md` gains a Systems step in the adaptation, modelled on
  F19: declare the systems, run `access.py check` and the first
  `access.py probe`, add a guard row for each vendor command line the guard
  lacks, verify and enable that product's connectors. In the carrier, the
  operator or an agent runs the probe on request. The carrier
  declares GitHub as its one system and ships no vendor rows or connectors
  of its own.

Acceptance: (1) in a repository whose policy lists a system with a failing
probe, the session-start note says unreachable, with the exit status and no
probe output; (2) a system whose declared read command is a write the guard
knows is refused by `access.py` by name.

### Unit 1 — research before the plan

- 1.1 A new playbook, `plan-research.md`, gives the findings table: claim,
  evidence as path and line, status (`observed`, `inferred`, `not read`), the
  commit read at, constraints, open questions, one page at most, and a
  re-check of rows whose files changed before implementation starts.
  `observed` means the line was opened or a command was run and its output
  quoted. The controller's `research` role text carries the return shape
  into every research brief. `explorer` returns it for lines it opened; a
  row that needs a command goes to a generic research cell with a shell, on
  the medium tier at Critical (F4).
- 1.2 The Build table gains a Research row before Plan, and the Plan row says
  the plan states as fact only what the findings mark observed; an inferred
  or unread claim becomes a spike or a question. The Spec playbook's
  ground-claims row takes the same table. At Standard the lead may write the
  findings itself; at Critical a fresh read-only cell does. Pass condition,
  two fresh headless sessions: a Standard Build writes a findings table
  before its plan, and its plan states no claim the table marks inferred.
- 1.3 Dropped after its test. A fixture plan with one planted false
  `observed` claim was reported false by reviewers under the committed
  contract in two of two runs, as under the drafted line, so the line would
  change nothing (`knowledge/research/2026-11-10-contract-wording-in-fresh-sessions.md`).

Acceptance: a Standard Build in a fresh session writes a findings table
before its plan, and a session with neither the Research row nor the playbook
does not; a Critical Build dispatches a fresh read-only cell for the table;
implementation re-opens a row whose file changed since the table was read.

### Unit 4 — owed-work flags

Flags inform; none of them blocks (ruling 3).

- 4.1 `hooks/lib/owed.py` computes four flags for a session from F9's
  records, so history from before this unit and other sessions' commits
  never raise one.
  - Review. The unit of cover is a file's content, not a commit, because
    commits are folded, squashed and merged between review and push. A
    review round is recorded as `docs/reviews/<date>-<slug>.md` carrying one
    line `Covers: <base>..<tip>`; the review playbook gains that sentence
    and names the file as the round's one ledger (F10). A file on
    `owed.critical_paths` that the session committed is `reviewed` when its
    content at HEAD equals its content at some record's tip, `changed since
    review` when a record's range touched it and the content has moved, and
    `unreviewed` otherwise. After folding a round's fixes the lead moves the
    record's tip, which the playbook's rule that a `P2` fix does not reopen
    a round allows; a `P0` fix gets a new round and its own record. A record
    whose tip git cannot resolve covers nothing and is named.
  - Suite. `.agents/suite.sh` runs the repository's `owed.suite` command and,
    when it passes, records the tree it passed on; the flag is raised while
    the session's tree differs from the last recorded pass. The carrier's
    suite is one script holding the Verification list; `.agents/AGENTS.md`
    names the script in place of the list, and a lint row fails when
    `ci.yml` runs a check the script lacks, or the reverse (F11).
  - Report: the existing long-session measure. Work log: the existing
    reminder (F8). Clean-up: resources in the teardown ledger, the session's
    worktrees, its untracked files.
- 4.2 `session-wrap.sh` keeps its measures and attribution and loses its
  questions on Claude Code: it writes the flags to its readout and, when a
  flag changes, shows one line through `systemMessage` (F12, F13). On Codex and Kimi the hook keeps today's question, because no
  non-blocking carrier is known there (F8, decision
  `mods-where-value-exceeds-portability`). `test-session-wrap.sh` keeps its
  attribution cases and replaces its message cases.
- 4.3 The push prompt. `guard-publish` already asks on every push (F14); its
  reason gains the owed line for the commits the push carries, read from
  `owed.py`. The test asserts the line's presence for an unreviewed
  critical-path file and its absence once a record covers it.
- 4.4 Claude Code cuts the readout row at the terminal's width and does not
  wrap it, so the readouts after the cut do not show (live check, review
  `2026-11-12-session-wrap`). `readout.py strip` puts the owed flags first
  and the other readouts after them by name; a test row with five readouts
  asserts the order.
- 4.5 `guard-publish` asks before `gh secret set`, `gh variable set`,
  `gh run rerun`, `gh run cancel`, and a `gh` write behind `xargs`, which it
  lets through today (review `2026-11-12-harness-w1`, unit 7 finding 8;
  ruling 5). Its own commit, with a test row per command.

Acceptance: (1) a session that commits code ends its turn with no question
and with the flag in the status strip; (2) a critical-path file committed and
not reviewed is named in the push prompt, and is not named once a record
covers its content; (3) a fix-up folded into a reviewed commit shows `changed
since review`, and moving the record's tip clears it; (4) the suite flag
clears after `suite.sh` passes and returns after the next edit.

### Unit 5 — background work that reports

Progress is observed by a hook, not reported by the agent, so a silent or
stuck agent still shows an age and a read-only cell is asked to write
nothing.

- 5.1 The inbox hook, which already runs between a subagent's tool calls,
  stamps the run state with the time and a few words of the agent's last
  action, at most once a minute per agent. A lane is bound by its claim
  (F16). The adapter passes the inbox hook `transcript_path` as it does for other
  hooks (F28), and the hook binds the agent to its cell by either brief
  header in its own transcript's first prompt. The first step proves F29 on
  a real cell; if no binding is possible, a cell shows only its time out, and
  the plan returns to the lead.
- 5.2 `status` and `watch` print, per lane and cell, time out and time since
  last activity, and `watch` reads the stamp for its stale rule (F15).
  `digest <run>` prints one line per agent: name, role, state, age, last
  action. The unit writes a readout line: agents out, the oldest silence.
- 5.3 The workloop skill's existing instruction to schedule `watch` (F17) is
  amended in place: the lead posts the digest when it changed and ends the
  loop when `check` passes. `claude/delegation.md` points at that line and
  restates nothing. The cadence is tried in a real run before the wording
  lands. Pass condition, two fresh headless sessions: a lead with a
  background run out schedules the loop unprompted.

Acceptance: (1) with two background agents out and one silent, `status`
names the silent one and its age; (2) `digest` shows each agent's last
action without the agent having run any controller command; (3) an idle lead
posts a digest without being prompted.

Left out: restarting an agent that died at a usage limit or a dropped
connection, and moving more of the lead's own work into the background. Both
belong to the work-loop redesign the operator approved outside this batch.

### Unit 2 — verification by execution

- 2.1 The plan lists its acceptance as numbered observable behaviours with
  expected values, written before code and committed with the plan; work
  with no plan carries them in its lane brief (F27). QA receives the ask,
  the acceptance and the run commands, and no diff (F6). The controller lets
  `qa` be recorded once every lane is submitted, so QA and review run side
  by side; the record stores the lane tips it ran against, on the integrated
  tree when the run has several lanes, and `check` reports `qa:stale` when
  any tip has moved since (F7). Firing test: QA recorded, a lane reopened
  and resubmitted, `check` fails. Pass condition for the contract wording,
  two fresh sessions: a Standard Build's plan carries numbered acceptance
  before any code is written.
- 2.2 The disprove pass, for a code review at Critical: each `P0` or `P1`
  resting on `inspection` goes to a QA cell that tries to reproduce or
  refute it by running something in a scratch folder outside the checkout,
  and returns `confirmed`, `refuted` or `unverified` with the command and
  its output. It never removes a finding, and `unverified` stays blocking.
  This replaces the labelling-only review of the review (F5) in the review
  playbook and in the Build table's Critical cell, outside the fenced
  contract. Pass condition, two fresh runs: a planted false `P1` comes back
  `refuted` with its command.
- 2.3 `.agents/revert-check.sh <base> --tests <paths> -- <command>` proves a
  fix's test catches the defect. In one provisioned scratch worktree at the
  fix it runs the command, which must pass; it then restores every changed
  file except the named tests to `<base>` and runs the command again, which
  must fail. The passing run proves the environment works, so a missing
  dependency or a missing test file cannot count as the failure (F27).
- 2.4 The QA skill notes the time each scenario starts and afterwards reads
  the log of the environment it ran against, by the log command unit 7
  declares for that environment; an error logged in that window during a
  passing scenario is a failure.

Acceptance: (1) a QA brief holds acceptance lines and no diff; (2) QA
evidence taken before a lane moved makes `check` fail; (3) a planted false
`P1` comes back `refuted` with its command; (4) `revert-check.sh` fails a
test that passes with the fix reverted, and fails with a message naming the
environment when the command cannot run at the fix.

## Order

Four waves of at most three writers, each writer in its own lane; another
session is writing in this checkout. A unit sits wholly inside one wave, and
a wave integrates only after its units' reviews and QA.

0. Unit 0.
1. Units 9, 7 and 1.
2. Units 4 and 5.
3. Unit 2.

Shared files set the order. The status strip and the session-start script
are written once, in 0.2. The root contract is written in waves 0, 1 and 3
(0.1, 1.2, 2.1 and 2.2); the review playbook in waves 0, 2 and 3 (0.1, 4.1,
2.2); `policy.json` in waves 1 and 2 (7.1, 4.1); the controller and its test
in waves 1, 2 and 3 (1.1, unit 5, unit 2), so the two units that both edit
the brief builders never run together. Unit 2 consumes unit 7's log command.

Each wave gets one review round: one cross-functional reviewer per unit,
each given the wave's whole diff and told to read its unit's seams with the
others, plus QA of each unit's acceptance. About 21 chunks and seven unit
reviews in four rounds, roughly 6.5M tokens. Satellites receive nothing
until asked.

Lenses:
- What higher-level abstraction would make this entire problem disappear? —
  a readout computed from state and built once (0.2) in place of four
  questions or silences; progress observed by a hook in place of progress an
  agent must remember to report; review cover defined on a file's content in
  place of commit hashes that every fold and merge rewrites.
- Reduce this problem to its irreducible constraints and rebuild it from
  zero. — a hook cannot see an answer or wake an idle lead (F8, F17); the
  inbox hook sees an agent only through its own transcript (F16, F28); the guard already asks on every
  push, so a push can carry a readout and gains no gate short of a refusal
  (F14); the reviewer contract is graded (F2); history is rewritten between
  review and push.
- Carve the problem at the joints. — by the state each readout is computed
  from: a session's edit records (4), run state (5), declared probes (7),
  checker configuration (9); and by who consumes a fact before acting: the
  plan's author (1), QA and the reviewer (2).
- What would a principal architect immediately rewrite before even starting
  this? — `session-wrap.sh` mixes measuring with asking, so the measure
  stays and the asking goes; a test run at the parent commit proves nothing
  about a test that does not exist there, so the check reverts the fix
  under the test instead.
- Find every implicit state machine. — a critical-path file (unreviewed,
  reviewed, changed since review; moved by a record's tip or a new round);
  QA evidence (missing, current, stale when a tip moves); a tree (suite not
  run, passed, stale); an agent (out, quiet, returned, failed); a system
  (unchecked, reachable, unreachable, stale); a checker (not configured,
  active, configured and missing, ran and unreadable); a finding (reported,
  confirmed, refuted, unverified, dispositioned). Each becomes a stored
  field with a named transition.
- Concession drift: you will get money pumped. — a flag nobody acts on
  becomes wallpaper, so each flag is true only while something is owed,
  clears itself, and appears in the push prompt, where the operator already
  decides; a fix after review that raised the flag again would buy a review
  per fix, so the lead moves the record's tip for a `P2` fix; a disprove
  pass could become a way to drop findings, so it labels and never removes.

## Review

One round at `7d10c5c`. The lead re-ran or re-opened the evidence behind
findings 1, 3, 6, 8, 9, 17 and 19, and each held.

| # | Finding | Disposition |
|---|---|---|
| 1 `P1` | The push refusal adds no gate: the guard already asks on every push | Adopted. 4.3 is a line in the existing prompt and claims no refusal; ruling 3 declined a refusal |
| 2 `P1` | Cover by commit range breaks on folds, later fixes, merges, old history and a missing record | Adopted. Cover is by file content, scoped to the session's commits, with a named transition and a contract line for the record (4.1) |
| 3 `P1` | One reviewer per unit contradicts the contract as committed | Adopted. Chunk 0.1 lands the rule first; ruling 4 sets this build's regime |
| 4 `P1` | Units split across waves integrate unreviewed | Adopted. Each unit sits in one wave |
| 5 `P1` | Units 2 and 5 both edit the brief builders in one wave | Adopted. Unit 5 in wave 2, unit 2 in wave 3 |
| 6 `P1` | QA recorded before a lane moves passes `check` on old code | Adopted. The record stores tips; `qa:stale` (2.1) |
| 7 `P1` | A test run at the parent commit passes on a missing file or dependency | Adopted. Replaced by the revert check (2.3) |
| 8 `P1` | tsc scoping and pyright's discarded output are silent paths too | Adopted. 9.2; the rising-count rule for unedited files is the lead's call |
| 9 `P1` | F16 partly false; the controller has no way to find a transcript | Adopted. F16 corrected; the hook stamps state (5.1); the cell binding is F28 and F29, F29 probed first |
| 10 | The `systems` shape cannot hold a browser-only system or a test identity | Deferred with a breadcrumb; scope stated in unit 7 |
| 11 | Probe output and misdeclared commands; who owns which file; who runs the probe | Adopted. 7.1 and 7.2 |
| 12 | Stripe and Sentry rows built ahead of need | Adopted. Dropped; rows are added at a satellite's adaptation (7.3) |
| 13 | Four copies of one readout | Adopted. Chunk 0.2 |
| 14 | The suite script is a third copy of the Verification list | Adopted. One script, named by `.agents/AGENTS.md`, with a lint row against `ci.yml`; `ci.yml` itself is not restructured, since it cannot be run before a push |
| 15 | The work-log reminder and the Codex and Kimi signal vanish with the question | Adopted. Work log is a flag; Codex and Kimi keep the question (4.2) |
| 16 | A read-only cell told to write run state | Moot. Cells run no controller command; the hook observes them (5.1) |
| 17 | F17 missed the existing `watch` instruction | Adopted. F17 corrected; 5.3 amends that line |
| 18 | The disprove pass named an impossible evidence tag and no stakes or workspace | Adopted. 2.2 |
| 19 | Acceptance stored in a folder teardown deletes | Adopted. Committed with the plan (2.1) |
| 20 | QA would read the hosted log while testing locally | Adopted. A log command per environment, read by time window (7.1, 2.4) |
| 21 | Detection list incomplete; the once-only ledger races | Adopted. 9.1 |
| 22 | Unit 5 builds reports and no resume | Declined for this batch: the operator's batch leaves out the work-loop redesign that owns resume. Stated under unit 5 |
| 23 | The measuring script has no consumer | Adopted. Dropped |
| 24 | Contract rewrites with no fresh-session test named | Adopted. Pass conditions in 0.1, 1.2, 2.1, 2.2 and 5.3 |
| 25 | Critical research on the lightest tier with no shell | Adopted. 1.1 |
| 26 | Four lens answers rest on settled or wrong ground | Adopted. Rewritten above |

## Changed after the operator's OK

Each is the lead's, reversible, and named here so the plan does not read as
the text the operator approved.

- 7.2: a repository never probed shows no systems line, where the approved
  text had the session-start note say to run the probe (review
  `2026-11-11-harness-u0` finding 1).
- 1.3: dropped, since reviewers caught a planted false claim without its
  line; unit 1's acceptance names its controls (review
  `2026-11-12-harness-u1`).
- 4.2: the attended-terminal fallback is gone, since F13 was observed in an
  interactive terminal.
- F28 and F29: the inbox hook's binding to a cell is half observed; 5.1
  keeps its fallback.
- 9.2: a broken caller is a tsc error line the session has not seen, where
  the approved text compared counts, which miss a break made while another
  error is fixed; pyright, which reads only the edited files, has no such
  rule (review `2026-11-12-harness-w1`, unit 9 finding 1).
- 9.3: the readout names missing checkers only, where the approved text
  also named active ones, since writing it on every run adds to each edit's
  cost (same review, findings 6 and 12).
- F22: true only for Codex and Kimi lanes; Claude lanes already ran ESLint
  and Prettier (same review, finding 14).
- 4.4: added, since the live check showed the host hides readouts past the
  terminal's width (review `2026-11-12-session-wrap`, findings 7 and 9).

## Rulings

Ruled by the operator on 2026-11-11.

1. The commits land on `main` through lanes, as this repository does; no
   build branch.
2. The research step applies at Standard stakes, written by the lead, and at
   Critical, written by a fresh read-only cell.
3. A push that carries a critical-path file with review owed is named in the
   push prompt and the operator decides; no refusal is built.
4. This build's units get one cross-functional reviewer each, with QA, and
   the lead walks the operator through the session-end hook change (4.2) and
   the QA gate change (2.1).
5. Ruled on 2026-11-12: the five GitHub writes the publish guard lets
   through are fixed in unit 4, which already edits the guard (4.5).

Decided by the lead, open to reversal: chunk 1.3 is dropped, since reviewers caught a planted false claim without its line, and unit 1's acceptance names its controls (2026-11-12); QA and review run side by side, with
QA evidence bound to the tips it ran on (2.1); tsc errors outside the
edited files are reported only when a line the session has not seen appears
(9.2); Codex and Kimi keep today's session-end question (4.2); a probe runs
on request, never at session start (7.2); the carrier ships no vendor rows
or connectors (7.3); `ci.yml` keeps its steps, held to the suite script by a
lint row (4.1); the ESLint message of F23 gets a test and no redesign.

Out of this build, noted: systems read only through a signed-in browser, and
test identities; restarting a dead agent; alert webhooks that start a
session; `printenv` and `curl` on the SSH read-only list can carry a secret
into a transcript; the `hosts` field of `mcp.json` is decided and unbuilt.

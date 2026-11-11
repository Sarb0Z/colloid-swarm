# Harness build-out: six units, planned

Workflow: Scaffold · Stakes: Critical (the root contract, the playbooks, the
reviewer contract, and the `session-wrap`, `post-edit-check` and
`guard-publish` hooks).

**Gate: open.** No code in any unit before the operator's OK on this plan.
The grilling step is folded into "Open rulings" below, because the operator
ruled on the design across the session that produced this plan
(`.agents/decisions.md`: `review-at-delivery-boundaries`,
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

## Findings the plan rests on

Read at `c31b533` by six read-only cells (run `harness-build-research`) and
the lead. Status is `observed` (the line was opened, or the probe was run) or
`inferred`.

| # | Claim | Evidence | Status |
|---|---|---|---|
| F1 | A plan has no committed path or schema, and no hook reads one; the only mandated structure is the Plan row and its `Lenses:` block | `AGENTS.md:46`; `rg plan .agents/hooks` | observed |
| F2 | The reviewer contract is the fenced block of `hostile-review.md`; `test-review-contract.sh` fails when it differs from `eval/review-harness/contract.md`, and `extract-contract.sh` regenerates that copy and requires a fixed list of strings | `hostile-review.md:17-82`; `eval/review-harness/bin/extract-contract.sh:23-60` | observed |
| F3 | The root contract is 21,163 bytes against a 24,000-byte warning | `lint-contract.py:18`; `wc -c AGENTS.md` | observed |
| F4 | `explorer` is pinned to haiku and returns `CONCLUSION / EVIDENCE / GAPS`, with no commit and no status per claim; a research cell's brief carries only the role line "find and ground the facts the objective needs, each with its source and date" | `personas/explorer.md:4-23`; `workloop_cells.py:21` | observed |
| F5 | The reviewer persona says "Do not edit, test, or delegate", so `evidence:reproduced` has no sanctioned producer inside a review; the Critical review of the review labels findings supported or unsupported and runs nothing | `personas/reviewer.md:12`; `hostile-review.md:116-124` | observed |
| F6 | QA receives "the ask, plan, changed paths, runnable commands" and derives its scenarios afterwards; nothing stores expected behaviour before the code | `skills/qa-verifier/SKILL.md:14-20` | observed |
| F7 | The root Build table puts QA before code review; the controller refuses `qa` until every lane is `reviewed` | `AGENTS.md:51-52`; `workloop_finish.py:44-52` | observed |
| F8 | `session-wrap.sh` has one blocking exit, fed by three messages that tell the agent to ask the operator; it cannot see the answer, so a skip is recorded only as "asked" | `session-wrap.sh:504-551, 557-600, 641-643` | observed |
| F9 | `edit-record.sh` already records, per session, the paths its editors wrote and the commits it made | `edit-record.sh:5-26, 105-154` | observed |
| F10 | A review is recorded as prose in `docs/reviews/*.md` with no machine-readable commit range, and as `accepted_tip` in the gitignored run state, which is absent outside a run | `docs/reviews/2026-11-11-scrapling-u2.md:1-20`; `workloop_lanes.py:137-166` | observed |
| F11 | Nothing records that the full suite ran on a commit; the carrier has no single suite command, only the list in `.agents/AGENTS.md` and `ci.yml` | `rg` of hooks and tests; `.github/workflows/ci.yml:36-91` | observed |
| F12 | A hook's JSON output may carry `systemMessage`, "Warning message shown to the user" | code.claude.com/docs/en/hooks, read 2026-11-11 | observed |
| F13 | A Stop hook that exits 0 with `systemMessage` shows the line without continuing the turn | the same page does not say so | inferred |
| F14 | `guard-publish` recognises `git push` as a parsed verb and receives the command, `cwd` and `permission_mode`; it does not resolve which commits a push carries | `hooks/lib/guard-publish.py:502-510, 941-964` | observed |
| F15 | A lane stores `heartbeat_at` and a `progress` string, with no stated cadence; a cell stores only `out_since` and `returned_at`; `status` prints no ages | `workloop_lanes.py:248-259`; `workloop_cells.py:71-119, 54-59` | observed |
| F16 | Each subagent has a transcript at `<session>/subagents/agent-<id>.jsonl` whose first prompt carries the `WORKLOOP CELL BRIEF — <run>/<name>` header, and the gate already reads those transcripts | `hooks/lib/cell_markers.py:16, 47`; `workloop_cells.py:150-152` | observed |
| F17 | A hook cannot wake an idle lead; the lead hears its digest only when the operator next types | `workloop-inbox.sh:22-24` | observed |
| F18 | The status line reads the host's JSON and git only; its test fixture copies two files | `claude/statusline.sh:44-68`; `test-statusline.sh:17-18` | observed |
| F19 | The transplant procedure already has a per-repository adaptation step that records "access snapshot, credential path" by hand in the gitignored `CLAUDE.local.md`; the tax-appeals-app repositories hold a hand-written list of probes such as `vercel whoami` | `export/README.md:215-220`; `tax-appeals-web/CLAUDE.local.md:10-20` | observed |
| F20 | `guard-publish` has write-verb rows for vercel, netlify, wrangler, firebase, fly, railway, supabase, terraform, gcloud, aws and gh, and none for the Stripe or Sentry command lines | `hooks/lib/guard-publish.py:57-90, 163-226`; grep | observed |
| F21 | `post-edit-check.sh` skips a checker whose binary it cannot find and prints nothing, for ruff, eslint, prettier, tsc, pyright and the Dart analyzer | `post-edit-check.sh:194-203, 241-281, 345-443`; `hooks/lib/js-groups.py:46-65` | observed |
| F22 | In a tree whose `node_modules` is a symlink to another tree, `js-groups.py` returns no group, so ESLint and Prettier never run there; `worktree-provision` shares `node_modules` by symlink by default | probe run 2026-11-11 (0 groups linked, 1 group copied); `worktree-provision.sh:32, 65-73` | observed |
| F23 | The "eslint … Nothing was linted" message does block (exit 2); its 1,056 logged lines are 1,052 from claims-app in 2026-09 and 4 from delivery-web, and ESLint runs clean in both today | `post-edit-check.sh:331-333, 475-483`; log count and two runs, 2026-11-11 | observed |
| F24 | `test-post-edit-check.sh` pins the Dart paths, one ESLint working-directory case and the path guards; nothing pins ruff, tsc, pyright or a checker that cannot run | `test-post-edit-check.sh:49-166` | observed |

## The shape shared by four units

Units 4, 5, 7 and 9 each replace a question or a silence with a readout
computed from state: what is owed, what is running, what is reachable, which
checks are active. They share three surfaces and nothing else: one line in the
status strip read from a cache file, one section of the session-start note,
and one command that prints the full readout. No shared framework is built;
each unit writes its own small computation and its own cache line.

## Units

Each unit is one delivered scope: its chunks are sized for one agent run of
about 200k tokens, a chunk gets no reviewer, and one cross-functional reviewer
reviews the unit at its boundary, with QA of the claim beside it. Every hook
change ships with a firing test that fails without it.

### Unit 9 — checks that cannot go silently missing

A repository that configures a checker has asked for it. The hook treats
"configured but could not run" as a finding and "not configured" as silence.

- 9.1 `js-groups.py` accepts a `node_modules` that links to the main tree of
  the same repository (F22), with test rows for the linked and the foreign
  case. `post-edit-check.sh` reports a configured checker whose binary is
  missing (a ruff section in `pyproject.toml` or `ruff.toml`, a flat ESLint
  config, a `tsconfig.json`, a pyright config) once per session and
  workspace, naming the install command, then stays quiet about it.
- 9.2 Firing tests for ruff in both modes, tsc, pyright and the ESLint
  no-report path (F24). The session-start note gains one line naming the
  checkers active and missing in the repository.

Claim QA reproduces: in a lane worktree with linked `node_modules`, an edit
that introduces an ESLint error is reported; in a repository with a ruff
config and no ruff binary, the first edit names the missing checker.

### Unit 4 — owed-work flags

- 4.1 `hooks/lib/owed.py` computes four flags for a session from F9's
  records: review owed (its commits outside every recorded review range),
  suite owed, report owed (the existing long-session measure), clean-up owed
  (resources in the teardown ledger, its worktrees, its untracked files).
  A review file gains one machine-readable line, `Covers: <base>..<tip>`
  (F10); `policy.json` gains `owed.critical_paths`, a list of globs, and
  `owed.suite`, the repository's suite command (F11). The carrier declares
  both, with a suite script that runs the Verification list.
- 4.2 `session-wrap.sh` keeps its measures and attribution and loses its
  three questions: it writes the flags to a cache file and, when a flag
  changes, shows one line through `systemMessage` (F12). The first step is a
  probe of F13; if a Stop hook cannot show a line without continuing the
  turn, the line moves to the next prompt's context and the status strip
  alone. `test-session-wrap.sh` keeps its attribution cases and replaces its
  message cases. The session-start note carries the flags forward.
- 4.3 The status strip draws the cache line (F18), with its test.
- 4.4 The suite record: `edit-record.sh` notes a passing run of `owed.suite`
  with the tree it ran on. `guard-publish` resolves the commits a `git push`
  carries (F14) and, where one touches a critical path and lies outside every
  review range, answers through its existing ask-or-deny path, naming the
  commits.

Claim QA reproduces: a session that commits code ends its turn with no
question and with the flag in the status strip; a push carrying an unreviewed
commit on a critical path is refused by name, and passes once a review file
covering it is committed.

### Unit 5 — background work that reports

- 5.1 The controller gains `note <run> <name> --progress '<text>'`, open to
  lanes and cells without a claim, stored with its time; `status` prints each
  agent's time out, time since last activity and last note; `digest` prints
  one line per agent. Every brief asks for a note at each milestone.
- 5.2 Last activity comes from the agent's transcript, bound to its cell by
  the brief header (F16), so a silent agent still shows an age. The inbox
  hook writes a one-line cache for the status strip, drawn after unit 4's
  segment.
- 5.3 `claude/delegation.md` tells a lead with background agents out to set
  a recurring wake and post the digest when it changed (F17). The cadence is
  tried in a real run before the wording lands.

Claim QA reproduces: with two background agents out and one silent, `status`
names the silent one and its age; an idle lead posts a digest without being
prompted.

### Unit 7 — read access, declared at the transplant

- 7.1 `policy.json` gains `systems`: for each system the product runs on, its
  name, a probe command that exits 0 when reachable, the read commands, and
  the log command. `.agents/access.py probe` runs the probes with a short
  timeout and caches the result for the day; values never enter the file.
- 7.2 The session-start note prints the cached table and its age.
  `stop-investigate.sh`, which already stops a turn that claims it cannot do
  something, names `access.py probe` in its message.
- 7.3 `guard-publish` gains write-verb rows for the Stripe and Sentry command
  lines (F20), with test rows.
- 7.4 `export/README.md` gains a Systems step in the adaptation, modelled on
  F19, and the carrier declares GitHub as its one system. Vendor connectors
  are verified and enabled per repository at adaptation, not shipped in the
  carrier's registry.

Claim QA reproduces: in a repository whose policy lists a system with a
failing probe, the session-start note says unreachable and quotes the probe's
error; a Stripe write command draws the guard's ask.

### Unit 1 — research before the plan

- 1.1 A new playbook, `plan-research.md`, gives the findings table: claim,
  evidence as path and line, status (`observed`, `inferred`, `not read`), the
  commit read at, constraints, open questions, one page at most, and a
  re-check of rows whose files changed before implementation starts. The
  controller's `research` role text carries the return shape into every
  research brief, and `explorer` returns it (F4).
- 1.2 The Build table gains a Research row before Plan, and the Plan row says
  the plan states as fact only what the findings mark observed; an inferred
  or unread claim becomes a spike or a question. The Spec playbook's
  ground-claims row takes the same table. At Standard the lead may write the
  findings itself; at Critical a fresh read-only cell does. Each wording is
  run twice in fresh headless sessions against a written pass condition
  before it lands.
- 1.3 The reviewer contract's static sweep gains, for a plan: open the cited
  lines of the claims the riskiest step rests on, and report a claim that
  does not hold. `extract-contract.sh` regenerates the graded copy (F2). The
  test is a fixture plan with one planted false `observed` claim, caught in
  both of two fresh runs.
- 1.4 A kept script counts serious finding lines per plan review from the
  session logs, against the mined baseline of 3.85.

Claim QA reproduces: the planted false claim is reported in two of two runs;
a Standard Build in a fresh session writes a findings table before its plan.

### Unit 2 — verification by execution

- 2.1 The plan lists its acceptance as numbered observable behaviours with
  expected values, written by the lead before code and stored in the run's
  folder. QA receives the ask, the acceptance and the run commands, and no
  diff (F6). The controller lets `qa` run once every lane is submitted, so QA
  and review run side by side at the boundary (F7).
- 2.2 After the reviewer reports, each `P0` or `P1` resting on `inspection`
  or `theoretical` goes to a cell that tries to reproduce or refute it by
  running something, and returns `confirmed`, `refuted` or `unverified` with
  the command and its output. It never removes a finding, and `unverified`
  stays blocking. This replaces the labelling-only review of the review (F5)
  and sits outside the fenced contract.
- 2.3 `.agents/red-at-parent.sh <base> -- <command>` runs a fix's test at the
  parent commit in a throwaway worktree and fails unless the test fails
  there.
- 2.4 The QA skill reads the application's log after each scenario by the log
  command unit 7 declares; an error logged during a passing scenario is a
  failure.

Claim QA reproduces: a QA brief holds acceptance lines and no diff; a planted
false `P1` comes back `refuted` with its command; a fix's test fails at its
parent by the script.

## Order

Three waves of at most three writers on disjoint files, each writer in its
own lane; another session is writing in this checkout.

1. Unit 9; chunks 7.1 and 7.4; chunk 1.1.
2. Unit 4; chunks 1.2 to 1.4.
3. Unit 5; unit 2; chunks 7.2 and 7.3.

Shared files force the order: the status strip (4 then 5), the session-start
note (9, 4, then 7), `guard-publish` (4 then 7), the root contract and the
reviewer playbook (1 then 2), the controller (1, then 5 and 2 on separate
modules). About 21 chunks and six boundary reviews, roughly 6M tokens.
Satellites receive nothing until asked.

Lenses:
- What higher-level abstraction would make this entire problem disappear? —
  a readout computed from state, shown in three fixed places, in place of a
  question or a silence (units 4, 5, 7, 9).
- Reduce this problem to its irreducible constraints and rebuild it from
  zero. — a hook cannot see an answer or wake an idle lead (F8, F17); the
  reviewer contract is graded (F2); the root contract has 2.8 KB left (F3).
- Carve the problem at the joints. — by surface, with the shared files
  setting the order.
- What would a principal architect immediately rewrite before even starting
  this? — `session-wrap.sh` mixes measuring with asking; the measure stays
  and the asking goes, with no rewrite of attribution.
- Find every implicit state machine. — a commit (unreviewed, reviewed, moved
  since review); a tree (suite stale, passed, failed); an agent (out, quiet,
  returned, failed); a system (unchecked, reachable, unreachable, stale); a
  finding (reported, confirmed, refuted, unverified, dispositioned). Each
  becomes a stored field.
- Concession drift: you will get money pumped. — a flag nobody acts on
  becomes wallpaper, so the push refusal is the one hard edge; a disprove
  pass could become a way to drop findings, so it labels and never removes.

## Open rulings

1. Where the commits land: `main` through lanes, as this repository does, or
   one branch for the build.
2. Whether the research step applies at Standard stakes, written by the lead,
   or at Critical only.
3. Whether the push refusal for unreviewed commits on critical paths is on by
   default in every satellite or switched on per repository; one satellite
   pushes its staging branch itself by an earlier ruling.

Decided by the lead, open to reversal: QA and review run side by side at the
boundary (2.1); vendor connectors are not shipped in the carrier (7.4); the
ESLint message of F23 gets a test and no redesign.

Out of this build, noted: alert webhooks that start a session; `printenv` and
`curl` on the SSH read-only list can carry a secret into a transcript; the
`hosts` field of `mcp.json` is decided and unbuilt.

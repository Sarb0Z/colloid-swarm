---
date: 2026-10-03
subject: The workflows the operator actually runs, mined from Claude Code and Codex session logs on this machine, and how each fits the contract's single six-step workflow
kind: research
source: see `## Sources`
---

# Workflows mined from session logs

The root `AGENTS.md` prescribes one six-step workflow for every task: research,
plan, hostile-review the plan, implement and test, QA, then hostile-review the
diff. Three read-only cells mined the session logs to find the workflows the
operator actually runs. Each cell covered a different set of projects and used
the same method:

1. Extract the genuine user prompts and tool signatures.
2. Segment each session into episodes, one per task.
3. Classify the episodes bottom-up.
4. Count with a script.

## Claims

Grades: `[A]` our own measurement. Episode boundaries and type labels are a
cell's judgement. The counts come from the cells' extractors.

### Coverage

- `[A]` The Claude Code logs held 263 main-session files. The cells used 238
  with prompts and found 473 human-driven episodes:
  - Cell A covered Incura, Meridian and three small projects: 113 episodes.
  - Cell B covered TaxDrop, Bitely, Mailstation, MemoGo and writing-coach: 272
    episodes.
  - Cell C covered colloid-swarm, career-ops and the root sessions: 88
    episodes, plus 24 nightly content-miner runs, which were excluded as
    automation.
- `[A]` Of 1,887 Codex files, only 372 are top-level user sessions. 211 of those
  are Claude history imported on 2026-08-03. Codex use ends on 2026-09-01.
- `[A]` The Claude logs on this machine start around 2026-09-05.
- `[A]` No episode was read line by line. Each cell read between 5 and 43
  episodes at summary depth and classified the rest from prompts and tool
  signatures.

### Workflow types across the 473 Claude episodes

The merge of the three cells' types is ours. The counts are their sums.

| Workflow | Episodes | Share | Contract steps that fit |
|---|---|---|---|
| Ask, lookup or status readout | 87 | 18% | Research only |
| Ship: commit, push, sync, merge, deploy, release | 73 | 15% | Research, plus QA after deploy |
| Ops and admin: infra, credentials, CI, servers, machine setup | 70 | 15% | None; the infrastructure-as-code rule applies |
| Feature build, delegated and long-running | 68 | 14% | All six |
| Debug, incident or screenshot UI fix | 53 | 11% | Research and implement-and-test; plan review is overkill |
| Docs, reports, EOD and assets in the user's format | 41 | 9% | None |
| Spec, plan, research and meeting intake | 40 | 8% | Research, plan and plan review; it often ends without a build |
| Scaffold edit and transplant | 18 | 4% | All six for transplants; research, implement and diff review for prose edits |
| QA of a deployed build, and the templated PR merge | 17 | 4% | QA standalone, implement, and review the diff |
| Domain runs (career-ops) and personal | 6 | 1% | None |

### Contract fit, measured

- `[A]` All six steps pay off for feature builds, transplants and large scaffold
  changes, about 18% of episodes. Ask, ship and ops episodes (48%) need none of
  steps 2 to 6.
- `[A]` Plan mode ran in 13 of 473 episodes.
- `[A]` Plan reviews are rare where diff reviews are common. In cell B's
  partition, 7 plan reviews ran against about 100 diff reviews. Cell A, where
  the clearclaim builds run through specs, counted about 59 plan reviews and 34
  diff reviews.
- `[A]` Docs and reports drew the highest correction rate:
  - Cell B counted 6 corrections in 40 prompts and cell A counted 9 redo prompts.
  - The prompts were of the form "this is not in my style, extremely verbose"
    and "doesn't look that good".
  - "Check session logs for previous EODs and follow that format and tone" was
    said 4 times.
- `[A]` Deploy and ops episodes drew the most challenges in cell A, 12 of them:
  - the agent asserted facts it had not fetched;
  - it ran production writes from `/tmp` scripts;
  - it orphaned 11 database roles in a staging outage;
  - it worked in the wrong account.
- `[A]` Debug episodes: 13 prompts quote the agent's own caveat back with
  "Fix.", usually a "pre-existing failure".

### Asks the operator re-types (each is a missing procedure)

- `[A]` Delegation and parallelism: about 30 prompts across the cells.
- `[A]` "Sync with remote": about 14 prompts.
- `[A]` Sample addresses: about 15 prompts.
- `[A]` "Update the worklog": about 25 prompts.
- `[A]` "Tear it down": 7 prompts.
- `[A]` The PR-merge instruction, pasted 8 times: "test merge and full engine
  suite. Also review the code yourself before merging".

### Hook cost

- `[A]` The session-wrap hook's end-of-turn question is the largest single
  source of user questions:
  - cell C: 45 of 77 AskUserQuestion calls;
  - cell A: about 135 of 279.
- `[A]` In cell A it blocked about 228 times, and 47 assistant messages are
  "wrap skipped, as you chose".
- `[A]` Status pings from the operator ("status?", "are you stuck?") appear
  about 40 times across the long builds.

## Implications for colloid `[A]`

- One workflow for every task is wrong for about half the work. A router fits
  the data better. It sends each task type to its own short procedure:
  - ask: answer from observed state;
  - ship: fetch before asserting, dry-run, then verify the deploy;
  - ops: back up first, keep production read-only until approved, write a
    runbook for the operator's hands, and keep changes in the repository;
  - docs and reports: show a format sample first and keep a stored style;
  - debug: give a root-cause report before the fix;
  - build: the full chain, plus status, stall and compaction handling;
  - spec: a spec may be the deliverable.
- A router table in `AGENTS.md`, with one playbook per workflow loaded on
  demand, reaches Codex and Kimi as well, so it needs no mod.
- The re-typed asks are candidates for skills or scripts, not contract steps.
- The session-wrap trigger should consult the workflow type, because its
  question interrupts finished ask and ship episodes most often.

## Sources

- `~/.claude/projects/*/*.jsonl`: the main sessions of 20 project directories,
  read by three cells on 2026-10-03. The cells' extractors and outputs are in
  `/tmp/workflow-mining/{A,B,C}/`.
- `~/.codex/sessions/**/*.jsonl`: 372 top-level sessions.

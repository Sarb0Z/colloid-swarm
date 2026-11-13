# Agent deaths U2: code review round 1

Unit U2 of `docs/handoff/2026-11-13-agent-deaths.md`, run `agent-deaths-u2`,
one writer lane `u2-commits` in the main checkout: a lane's writer commits each
piece by path as its acceptance passes (`working-practice.md`), the rule
`style-inject.sh` gives every cell names the lane's writer and a cell with no
lane, and `commit_nudge.py` behind the inbox hook tells a lane writer whose
oldest uncommitted edit is over 30 minutes old to commit, behind
`hooks.commit_nudge.enabled`. One reviewer (opus) read the scope whole and its
seams with the death reader, the inbox hook, `config.py`, the workloop guide
and `decisions.md`, under the verbatim contract; Critical stakes, since the
unit changes a contract every cell follows and a hook.

Covers: 906ab72..aab37e9

## Findings

| # | Sev | Finding | Evidence |
|---|---|---|---|
| 1 | P1 | The nudge runs `git status --porcelain -z -uall -- <paths>` in the shared checkout at each tool batch of a lane writer with dirty files, without `--no-optional-locks`; status takes `.git/index.lock` while it refreshes the index, so a concurrent `git add` or `git commit` in another session fails "Unable to create '.git/index.lock': File exists"; `agent_leftovers.py:103` (the death reader) runs the same at each lead prompt, while `statusline.sh:108`, `worktree_heal.py:163` and `worktree_removal.py:184` already pass the flag (`commit_nudge.py:58`) | inspection |
| 2 | P1 | Every QA brief, a lane's `qa` role and every QA cell, carries the whole working practice, so a QA cell is told "commit each piece … stage your lane's paths by path and commit on the branch of the tree your lane names", against the injected rule that only a lane's writer commits; `READ-ONLY` refuses Edit and Write, not a `git commit` in Bash; Acceptance 9 tests no lane QA cell (`working-practice.md:6`, `workloop_lanes.py:336`, `workloop_cells.py:156`, `personas/qa-verifier.md:51`) | inspection |
| 3 | P1 | The plan's exception, "a repository whose contract waits for the operator turns it off (E12)", reaches no such repository: the toggle defaults on, the export drops the carrier's `policy.json` (`export/README.md:269`), no sync or adaptation step sets it off, and the `COMMIT:` text lacks the working practice's "unless this repository says commits wait" (`workloop-inbox.sh:80`, `config.json.example:72`, `export/README.md:180-198`) | inspection |
| 4 | P2 | The toggle read discards `config.py`'s stderr (`2>/dev/null`) and `\|\| echo yes` turns the nudge on when `policy.json` or `config.json` fails to parse, so a repository that turned it off gets it back silently (`workloop-inbox.sh:80`; breadcrumbs.md:117 files the same pattern) | inspection |
| 5 | P2 | A second copy of "which of these paths does git list as changed": the nudge's parser drops a rename's from-path where the reader counts it, reads only the index column for `R`/`C`, and keeps inherited `GIT_*` variables where `GitBudget.out` strips them (`commit_nudge.py:56-66` against `agent_leftovers.py:101-111`) | inspection |
| 6 | P2 | `first_seen` drops a path after one status that does not list it and only a new editor record adds it back, so a stash and pop, a reset or a branch switch brings an old edit back unnudged; Bash-written changes are never seen; a commit and a re-edit in one batch keep the pre-commit time (`commit_nudge.py:96-103`) | theoretical |
| 7 | P2 | Each subagent tool batch in a checkout with a state file adds a `config.py` process and a `commit_nudge.py` process that imports `agent_effects` and with it the death reader's modules for one 8-line helper, before the lane check, so cells with no lane pay it too; per-batch cost and runs per day unstated (`workloop-inbox.sh:79-84`, `commit_nudge.py:35-37`) | inspection |
| 8 | P2 | Each lane writer leaves a `.commit-nudge-<agent>.lock` that `prune` keeps by design and nothing removes; a nudge failure reaches only a subagent hook's stderr, which the lead never sees, and its offset never advances (`commit_nudge.py:89-91, 121-125`) | inspection |
| 9 | P2 | A main lane's reviewer and QA briefs say "Commit on the checkout's current branch before submit", which the injected rule covers for neither (`workloop_lanes.py:298`) | inspection |
| 10 | P2 | The line does not order the claim first; a writer that commits its first piece before claiming leaves `submit` nothing to review, which breadcrumbs.md:63, 69 and 99 record (`working-practice.md:6`) | inspection |
| 11 | P2 | `implementer.md`'s short restatement of the working practice omits the new line (`personas/implementer.md:23-37`) | inspection |
| 12 | P2 | `agent_records.py` passes 300 lines (310) and 12 public entries | inspection |
| 13 | P2 | Case 9's failure messages read "8:"; no case covers a modified tracked file, a staged-only file or a rename; the toggle-off case checks silence, not that the offset stays (`test-commit-nudge.sh:125-126`) | inspection |

Checked and found sound by the reviewer: `dcc0028`'s skip of
`api-request-blob` records holds on this store's 9,062 subagent transcripts
that carry them (none names an edited path absent from the agent's `assistant`
records); the death reader isolates a failing agent and its code-hash cache
picks up the changed module; `lane_tree`'s keys match the controller's.

QA against Acceptance, by the reviewer: 7 has fixture runs only; 9 (b) has only
the writer's runs; 9 (c) has no control run without the sentence.

AMBIGUITY: who commits in a lane besides its writer — (a) only the lane's
writer; its reviewer and QA cells never commit, as `style-inject.sh:30` reads;
(b) any cell whose brief names a lane, as `working-practice.md:6` in QA briefs
and `workloop_lanes.py:298` in reviewer and QA briefs read; code: neither.

HANDOFF (reviewer): QA of Acceptance 7 live and 9 (b), (c) independently (a QA
cell is running both); reproduce finding 1's lock collision and finding 2's QA
commit.

## Disprove pass

One QA cell (sonnet) ran each `P1` against `aab37e9` in a scratch folder.

| # | Label | Command and output |
|---|---|---|
| 1 | confirmed | A repository of 600 tracked files, 20 modified and 3 untracked; one loop ran a status over six paths flat out for 30 s while another ran `git add d5/f5 && git reset -q d5/f5`. The nudge's form, `git -C <tree> status --porcelain -z -uall -- <paths>`: 285 of 851 add/reset runs failed "fatal: Unable to create '…/.git/index.lock': File exists."; the death reader's form (`agent_leftovers`): 311 of 925; with `git --no-optional-locks`: 0 of 928. The loop is denser than one status per tool batch, so the rate is not the real one; the collision is. |
| 2 | refuted (weak) | A clone at `aab37e9` with a lane `w1` holding one commit, and the QA brief `brief r1 w1 --role qa` wrote, which carries two commit instructions: the working practice's commit line and "Commit on the checkout's current branch before submit, staging by path only". Two headless leads, `CLAUDE_CONFIG_DIR=/Users/alice/.claude-personal command claude -p "$(cat …/disprove-u2/prompt.txt)" --model opus --output-format stream-json --verbose`, each dispatched the QA cell with the three dispatch lines and a task to write `notes/check.sh`. Sessions `6595d0cf` and `29881cd2`: each cell read the brief and ran `ls`, `cat`, `test -f` and `git status --short`, no `git add` or `git commit`; `git log` still ends at the lane commit `599d9d6`, the status is empty. Weak: both cells obeyed the brief's `READ-ONLY` line and wrote nothing, so neither had anything a commit line could apply to. (A first attempt had no `CLAUDE_CONFIG_DIR`, used the work account and stopped on its weekly limit.) |
| 3 | confirmed | `export-scaffold.py` at `aab37e9` built a kit whose `.agents/config.json.example` sets `"commit_nudge": {"enabled": true}` and which ships no `.agents/policy.json`; a scratch target whose `AGENTS.md` says "Commit and push only when asked.", given the kit by the first-sync step, read `python3 .agents/hooks/lib/config.py .agents/config.json hooks.commit_nudge.enabled=true` as `yes`. No step of the kit's `export/README.md` turns it off; `.agents/README.md:481-483` describes the exception, and the Adapt section's policy bullet names only the browser UI gate. |

## Dispositions

AMBIGUITY settled as (a), only the lane's writer commits: the plan's rule
(U2, "a lane's writer commits each piece"), and `style-inject.sh:30` already
reads so. The fixes below bring the brief lines and the working practice to it.

| # | Disposition |
|---|---|
| 1 | Fix. Every read-only Git call of the reader and the nudge runs with `--no-optional-locks`: `GitBudget.out` passes it, so the death reader, the digest and the nudge share one runner; rerun the disprove pass's two loops against the fixed form (0 failures expected). |
| 2 | Refuted as a `P1`, so it goes to the operator's walk-through with the command above. The text is fixed with 9 and 10, which change the same lines: the working practice's commit line names the lane's writer as its subject, and `test-workloop.sh` asserts that reviewer and QA briefs, of main and worktree lanes, and a QA cell's brief carry no instruction to commit; 9 (b) reruns twice on the new wording. |
| 3 | Fix. The export procedure's Adapt policy bullet names `hooks.commit_nudge.enabled: false` for a repository whose contract makes commits wait for the operator, and the `COMMIT:` line carries the working practice's "unless this repository says commits wait for the operator". The two tax-appeals-app repositories say "commit and push only when asked"; their next sync sets it off (operator notes). |
| 4 | Fix. The toggle is read inside `commit_nudge.py` through `config.py`'s library; a file that does not parse leaves the nudge silent and says so on stderr. |
| 5 | Fix with 1: one parser of `git status -z` for the reader and the nudge, which keeps a rename's from-path and strips inherited `GIT_*` variables. |
| 6 | Defer. A README line states that the nudge sees edits made with the editor tools only; the stash, reset and same-batch cases go to `breadcrumbs.md`. |
| 7 | Fix. The lane check runs before the death reader's modules are imported, and the toggle read is in-process (4), so a cell with no lane pays one Python start; the writer reports the measured per-batch time before and after. |
| 8 | Fix the file: no per-agent lock file stays after its lane ends. The routing of a nudge failure to the lead is deferred to `breadcrumbs.md`, beside the subagent-stderr gap. |
| 9 | Fix. The "Commit on … before submit" line goes into the worker's brief only, for main and worktree lanes alike. |
| 10 | Fix. The commit line orders the claim first: a lane's writer claims, then commits each piece. |
| 11 | Fix. `implementer.md` and `.codex/agents/implementer.toml` carry the commit clause in their summaries. |
| 12 | Accept. 310 lines; the module stays one reader of one record format. |
| 13 | Fix. Case 9's messages, and rows for a modified tracked file, a staged-only file and a rename; the toggle-off case checks the offset stays. |

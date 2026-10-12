# Plan: hook script lookup

Workflow: Build · Stakes: Critical (every guard and gate hook's entry point).

## Ask

The operator, on 2026-10-08, after two tax-appeals-app sessions ran with every hook
failing:

> what's going on

> its probably not just a colloid problem

Asked whether to plan "fall back to the right folder" and "fail closed when
nothing is found": "yes", no upstream comment. Grilling rulings, all as
recommended, recorded as decision `hook-script-lookup` and the glossary term
**Launch folder**:

1. Look in the launch folder first, then the working folder and each folder
   above it.
2. When nothing is found, a guard blocks the tool call; no per-call prompt.
3. Every tool call is blocked, reads included.
4. Every other hook shows a visible non-blocking notice naming the fix.
5. The status line shows the warning.
6. Sessions launched from a product folder (no project hooks at all) stay out
   of this change: breadcrumb.
7. Scaffold only. Satellites take it at their next sync; the two repositories
   outside the scaffold go to breadcrumbs; the operator relaunches the two open
   tax-appeals-app sessions now.

## Evidence

- `~/.claude/history.jsonl` records session `562d00be` launched from
  `/Users/alice/Projects/tax-appeals-app/tax-appeals-engine` until 2026-10-06
  12:19 UTC and from the product folder `/Users/alice/Projects/tax-appeals-app` after.
  `grep -c 'tax-appeals-app/.claude/hooks/adapter.sh: No such file' <transcript>` at
  2026-10-08 15:43 UTC: 1,124 lines in `562d00be` (first 2026-10-07 09:00
  UTC) and 471 in `8cc206f7` (first 2026-10-08 13:56 UTC, latest 15:40 UTC),
  all exit 127, and both sessions still running. The commands are the repository's own (`research-prime.sh`,
  `done-prime.sh` appear only in its settings), so Claude Code loaded the
  repository's hooks with `CLAUDE_PROJECT_DIR` at the product folder.
- Claude Code docs (code.claude.com/docs/en/hooks, read 2026-10-08): hook
  commands run as `sh -c` in the session's current directory;
  `CLAUDE_PROJECT_DIR` is "the project root where the session started" and
  stays there after a worktree entry or `cd`; exit 2 is the only code that
  blocks on its own, and its effect per event is: PreToolUse blocks the call
  and shows stderr to Claude; UserPromptSubmit erases the prompt; Stop and
  SubagentStop keep the agent running; PreCompact blocks compaction;
  PostToolBatch stops the loop; PostToolUse, SubagentStart and SessionStart
  only show stderr. Any other non-zero exit is a non-blocking error: the
  action proceeds and the transcript shows `<hook> hook error` with the first
  stderr line.
- Upstream: anthropics/claude-code#92168 (open) — a directory change loads the
  new folder's hooks but leaves `CLAUDE_PROJECT_DIR` at the launch folder.
  beep-effect#1314 adopted the same fallback shape.
- `.agents/claude/adapter.sh` resolves its repository from its own path and
  already fails closed when a named policy is missing; only the hook command
  that finds the adapter is fragile. `normalize-hook.py:55` takes
  `project_dir` from `CLAUDE_PROJECT_DIR` before the payload's `cwd`, so a
  fallback that leaves the variable stale would hand every policy the product
  folder as its project.
- `.agents/codex/hooks.json` already walks up from `$PWD` for its adapter and
  exits 2 (guard) or 0 (other) when none is found.
- `/bin/sh` on this machine is bash 3.2 in POSIX mode; `export X=1; exec env`
  passes `X`.
- `.agents/test-statusline.sh:99` runs the committed `statusLine` command
  against a fixture holding `.agents/claude/statusline.sh` but no hook
  adapter, so the status line looks for its own script.

## Design

### `.agents/claude/settings.json`: every hook command

Each of the 30 hook commands becomes one form, differing only in the exit
code, the optional `POST_EDIT_MODE=write` export, and the adapter arguments:

```sh
d=$CLAUDE_PROJECT_DIR;[ -f "$d/.claude/hooks/adapter.sh" ]||{ d=$PWD;until [ -f "$d/.claude/hooks/adapter.sh" ];do [ "$d" ]||{ echo "guards unavailable: no .claude/hooks/adapter.sh in the launch folder ($CLAUDE_PROJECT_DIR) or at or above $PWD; relaunch Claude Code from inside the repository" >&2;exit 2;};d=${d%/*};done;case $d in */.claude/worktrees/*) [ -f "${d%%/.claude/worktrees/*}/.claude/hooks/adapter.sh" ]&&d=${d%%/.claude/worktrees/*};;esac;};export CLAUDE_PROJECT_DIR="$d";exec bash "$d/.claude/hooks/adapter.sh" guard-destructive.sh
```

- Exit 2 for every `PreToolUse` entry, exit 1 for every other event. Blocking
  any other event does harm (an erased prompt, a stop loop, a compaction that
  never runs), and exit 1 is the documented visible non-blocking notice.
- The launch folder wins when it holds the adapter, so every setup that works
  today runs unchanged, and a workloop lane's half-edited guard never governs
  that lane. An empty or unset `CLAUDE_PROJECT_DIR` falls through to the walk.
- `export CLAUDE_PROJECT_DIR="$d"` hands the policies the folder whose adapter
  ran, so `normalize-hook.py` and `sources-ledger.py` read the right project.
  In the launch-folder case `d` is the variable verbatim, so nothing changes.
- A walk that lands in `<checkout>/.claude/worktrees/<lane>` maps back to the
  checkout when the checkout holds the adapter. An isolated cell's working
  folder sits there, and without the mapping its `SubagentStart` would keep the
  parallel-writers ledgers in the lane's `.agents/` while the lead's dispatch
  keeps them in the checkout's, letting a second writer into one tree. Claude
  Code keeps `CLAUDE_PROJECT_DIR` at the checkout after a worktree entry, so
  the mapping matches the launch-folder case.
- `exec bash` matches the Codex hooks and the adapter's own shebang lookup.
- `POST_EDIT_MODE=write` moves into the same `export`.

Known residue, stated in the README paragraph too:

- A session that moved from scaffolded repository A into scaffolded
  repository B runs A's adapter with B's hook list, and A's `policy.json`
  (hosted scripts, dry-run exemptions, switches) governs commands run in B.
  This is today's behavior. A policy B names and A lacks hits the adapter's
  existing missing-policy path.
- In a fallback session, the project each hook sees follows the working
  folder, so per-session state (wrap, UI, teardown and writer ledgers) splits
  across repositories when the session moves between them.
- In a fallback session, a `cd` into the product folder blocks every later
  tool call, the `cd` back included; the relaunch the message names is the
  only way out. This is ruling 3 applied, not a defect.
- A workloop lane provisioned outside its checkout, such as tax-appeals-app's
  `.worktrees/` in the product folder, resolves to the lane's own adapter in a
  fallback session.
- A satellite whose `.claude/hooks/adapter.sh` link is dangling moves, at its
  next sync, from silent exit-127 failures to every tool call blocked.

### `.agents/claude/settings.json`: `statusLine`

The same lookup for `.agents/claude/statusline.sh`; when nothing is found it
prints `guards unavailable: relaunch Claude Code from inside the repository`
and exits 0, so the warning is on screen before any tool runs.

### `.agents/test-hook-lookup.sh` (new; CI and the Verification list)

Builds a temporary product folder `pf/` with an empty `pf/.claude/`, a
repository `pf/repo/` holding stub `.claude/hooks/adapter.sh` and
`.agents/claude/statusline.sh` that print `CLAUDE_PROJECT_DIR`,
`POST_EDIT_MODE` and their arguments, and a second stub repository `other/`.
For every hook command and the `statusLine` command read from the committed
settings, under `sh -c`:

1. Launch folder `pf/repo`, working folder outside every repository: the repo
   stub runs with `CLAUDE_PROJECT_DIR=pf/repo`.
2. Launch folder `pf` (the tax-appeals-app case), working folder `pf/repo/sub`: the
   repo stub runs with `CLAUDE_PROJECT_DIR=pf/repo`.
3. `CLAUDE_PROJECT_DIR` unset, working folder `pf/repo`: the repo stub runs.
4. Launch folder `pf`, working folder `pf`: nothing runs; `PreToolUse` exits 2,
   every other event exits 1, each with the relaunch line on stderr; the
   status line prints the warning and exits 0.
5. Launch folder `pf/repo`, working folder `other/`: the `pf/repo` stub runs.
6. Launch folder bogus, working folder `/`: the walk ends with the step 4
   result.
7. Each command passes its adapter arguments intact; only the post-edit entry
   carries `POST_EDIT_MODE=write`.
8. Every `PreToolUse` command carries `exit 2` and no other does.
9. Launch folder `pf`, working folder `pf/repo/.claude/worktrees/lane` (a lane
   holding its own stub adapter): the `pf/repo` stub runs with
   `CLAUDE_PROJECT_DIR=pf/repo`.
10. With its exit code, its `POST_EDIT_MODE=write` export and its trailing
    adapter arguments removed, every hook command is byte-identical to the
    others, and the `statusLine` lookup matches it modulo the script name and
    the not-found branch. A hand edit to one of the 31 copies fails here.

One end-to-end row runs the real `guard-destructive.sh` entry with launch
folder `pf` and the real repository as working folder, on a `git reset --hard`
payload, and expects the deny. Run against `HEAD`'s settings, rows 2, 3, 4, 6
and the end-to-end row fail with exit 127.

### Documentation and records

- `.agents/claude/README.md`: one paragraph on the lookup and the
  missing-adapter behavior, beside the existing missing-policy paragraph.
- `.agents/decisions.md`: `hook-script-lookup` (written at the grilling);
  rewrite `status-strip-as-statusline-command`'s reopen clause, which says the
  committed command resolves the script only through `CLAUDE_PROJECT_DIR`.
- `.agents/AGENTS.md` Verification list, the test list in `.agents/README.md`
  and `.github/workflows/ci.yml`: add the new test.
- `.agents/test-statusline.sh:97-98`: the comment says the command resolves the
  script through `CLAUDE_PROJECT_DIR`; it now says through the launch folder
  first.
- `GLOSSARY.md` is untracked and carries the product-folder work's terms
  beside **Launch folder**; it stays out of this change's commits and lands
  with that work.
- Breadcrumbs (written at the grilling): product-folder launches; the two
  repositories outside the scaffold.

Not touched: `.agents/codex/hooks.json` (already walks up), Kimi (relative
paths resolved by Kimi), `adapter.sh`, every policy, `export-scaffold.py`
(drops hooks by policy name, which the new form still carries).

## QA claim

In a real Claude Code session whose launch folder is a product folder and
whose hooks come from a scaffolded repository inside it, a `git reset --hard`
in a scratch repository is denied by `guard-destructive`; and in a session
where no adapter is reachable, the first tool call is blocked with the
relaunch line. The vehicle is a scratch product folder under `/tmp` holding a
repository built from an exported kit (as `test-export.sh` builds one) and a
fresh session, never one of the operator's sessions or checkouts, so a failed
guard resets only a scratch repository. QA tries a fresh `claude -p` session
in the scratch repository resumed with `--resume <id>` from the scratch
product folder; if headless Claude Code cannot produce that state, the `sh -c`
rows with Claude Code's documented environment are the evidence and the gap is
stated.

## Review

Hostile review on 2026-10-08 (plan sha256 `11425590…`): P1 adopted (worktree
mapping, row 9). P2s adopted: counts restated from a named command; residue
documented; QA vehicle named; README list, statusline comment and sync note
added; byte-identity row 10. The reviewer confirmed the lookup under `/bin/sh`
and `dash` for rows 1-6, with spaces, an unset, empty, trailing-slashed or
bogus launch folder, a stale `PWD`, and the symlinked adapter.

The code review, its QA and every disposition are in
`docs/reviews/2026-10-12-hook-script-lookup.md`; the ruling-6 breadcrumb named
above lives in the debt log as `colloid-product-folder-sessions-unguarded`.

## Delivery

One `implementer` cell (medium) writes the settings rewrite, the test, CI and
the docs on the main tree; the lead reviews. Commits: the hook-command change
with its test, CI line and README paragraph; the records (decision, reopen
clause, Verification list) with it, since they describe it. Rollback: revert
the commit. Satellites change only at their next sync.

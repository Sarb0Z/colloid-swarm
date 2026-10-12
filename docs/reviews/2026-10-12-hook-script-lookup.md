# Review: hook-script-lookup (code round, 2026-10-12)

Plan: `docs/handoff/2026-10-08-hook-script-lookup.md`. Artifact: the uncommitted diff on `9edee4b`, sha256 `3db283c3…9da7c`. Three axis reviewers (contract and exposure; state and failure; system shape) and one review of the review, which labelled F7 unsupported and every other finding supported. The contract and state reviewers found the diff conformant; the system-shape reviewer did not, over F1.

Before review, the checkout fast-forwarded over 125 upstream commits. Six upstream hook entries (`edit-record.sh` ×3, `worktree-sessions.sh` ×3) arrived in the old command form and were converted to the lookup form by script, checked to reproduce the original rewrite byte for byte; `test-worktree-sessions.sh`'s registration check now matches the new form.

## QA

Live, headless Claude Code 2.1.294, scratch product folder under `/tmp`. With the launch folder lacking the adapter and the working folder inside the repository, `guard-destructive` denied `git reset --hard` (exit 2). With no adapter reachable, the first `ls` was blocked with the relaunch line; `UserPromptSubmit`, `PostToolBatch` and `Stop` exited 1 without blocking, and the prompt survived. Not reproduced: a session resumed from a product folder loads no repository hooks headless, so the literal tax-appeals-app state rests on the `sh -c` rows; the status line is not drawn headless.

## Findings

| # | Severity | Finding | Disposition |
|---|---|---|---|
| F1 | P1 | `test-hook-lookup.sh` hard-coded the hook count; exported kits drop `genome-inject.sh`, so the shipped test failed in every satellite | Adopted: a floor instead of a count; `test-export.sh` runs the kit's own test against the kit's settings |
| F2 | P2 | The end-to-end row passed on the not-found path and on the adapter's missing-policy deny | Adopted: requires exit 2, the guard's own text, and no relaunch line |
| F3 | P2 | Nothing asserted the match-all `PreToolUse` group that makes "reads included" true | Adopted: row 4 asserts it |
| F4 | P2 | No author guidance for registering a hook in the lookup form | Adopted narrowed: row 10's failure message says to copy an existing command; no prose rule, since CI already fails the class |
| F5 | P2 | The decision's Codex clause was inaccurate | Adopted |
| F6 | P2 | Switching to a branch that predates the scaffold blocks every later call, the switch back included | Accepted under ruling 3; documented in `.agents/claude/README.md` |
| F7 | P2 | The ruling-6 breadcrumb was missing | Declined: `colloid-product-folder-sessions-unguarded` in the debt log carries it (`b1d2922`) |
| F8 | P2 | The not-found walk runs to `/`, through ancestors Claude Code never reads hooks from | Accepted and documented; debt `colloid-hook-lookup-walk-unbounded`, which also records a hang reproduced under bash 3.2 with a deleted working folder and a relative `PWD` |
| F9 | — | After `EnterWorktree`, `edit-record.sh` snapshots the checkout's HEAD (upstream behavior) | Breadcrumb |

The showcase pages were re-embedded for this change, since CI regenerates them and fails on a dirty tree.

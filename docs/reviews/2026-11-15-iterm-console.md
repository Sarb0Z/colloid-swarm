# iTerm2 console: code review of workloop run `iterm-console`

Plan `docs/notes/2026-11-15-iterm2-review-and-status-spec.md`, approved by
the operator on 2026-11-15. Each lane gets one reviewer beside QA; the
sidebar lane is critical and adds the disprove pass.

## Lane `diff` (unit 1, standard)

Covers: f108fb9..cf9367c

One reviewer (sonnet) read the lane's diff; QA (sonnet) ran Acceptance 1-5
and probe P4 in headless Neovim with diffview-plus v0.39 over fixture
repositories.

QA: Acceptance 1 failed; 2, 3, 4 (no upstream and no remote), 5 and P4
passed, apart from the untracked files below. With the not-pushed base the
panel lists `a c1 c2 c3`, and git lists `a c1 c2 c3 untracked.txt`.

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | A commit base hides untracked files: diffview's `GitAdapter:show_untracked` returns false unless it compares the index with the working tree (`lua/diffview/vcs/adapters/git/init.lua:2536-2540`), and no flag overrides it. Reproduced by QA | Escalated: the operator's ruling "Not pushed, like reviews" promised the panel shows what a pane review reads. The operator ruled R20: a second tab with the uncommitted view when untracked files exist; the index is not touched |
| 2 | P1 | A typed base with `~ ^ { }` (for example `HEAD~2`, `@{u}`) is backslash-escaped, and diffview hands the backslash to `git rev-parse` | Adopted: escape only what diffview's tokenizer reads as syntax; tests and a real run with `HEAD~2` and `@{u}`; file names with `[`, `%`, `#` checked for real |
| 3 | P2 | `pane-base` reads only the `origin` remote; 1 of 87 repositories under `~/Projects` has only a remote named `server` | Filed in `breadcrumbs.md`: the lane does not otherwise change `pane-base` |
| 4 | P2 | `install.sh` refuses a dangling link left by a removed worktree | Declined: the runbook runs `install.sh` from the main checkout only, and Undo removes the links |
| 5 | P2 | No test runs `pane-diff` through the installed link; the usage branch and a mutation check were not run | Adopted: `pane-diff` and its tests change for finding 2 |
| 6 | P2 | The usage error exits without the key hold, and `pane-base`'s own reason is dropped | Adopted: same script |
| 7 | P2 | QA: `pane-diff @ -- <file>` also lists untracked files that are not the file | Accepted: diffview applies the path filter to tracked files only; the filtered view still opens on the file |

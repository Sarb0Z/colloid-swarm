# Fold-ins D3: plan review

The "D3 design" section of `docs/handoff/2026-11-12-job-tracker-fold-ins.md`
at `74e7a98`: `.agents/suite.sh` runs the checks of `.agents/check-all.sh`
from a copy of the checkout under a temporary `HOME`, and fails when a
watched real path changed during the run (plan finding F20). One reviewer
(opus) read the design, the code it rests on, and built a copy as described
under `$TMPDIR`, where `check-layout.py` and `test-mcp.sh` passed; Critical
stakes, since every session's suite goes through `suite.sh`.

## Findings

| # | Sev | Finding | Evidence |
|---|---|---|---|
| 1 | P1 | Under a temporary `HOME`, Playwright's browser folder does not exist, so the browser layers of `test-scrapling-launcher.sh` and `test-scrapling-proxy.sh`, metadata-address blocking and proxy redaction, print SKIP and the suite still passes; the design's rule covers checks that fail, not checks that skip | reproduced, offline |
| 2 | P1 | Five of the seven watched paths have live writers here: GitLens and `git push -u` write `.git/config`, a rebase moves `.git/HEAD`, Claude Code writes `.git/info/exclude`, Codex writes `~/.codex/config.toml` for each folder it trusts, `/effort` and `/theme` write `~/.claude/settings.json`; `.git/hooks/` is unused. A correct run fails whenever one fires | live |
| 3 | P1 | `/opt/homebrew/etc/gitconfig` sets `credential.helper=osxkeychain`, so acceptance 5 fails on the first run and a check's git call still reaches the keychain; `GH_TOKEN` is inherited too | reproduced |
| 4 | P2 | The tree is taken before the working files are laid over the copy, so an edit in between records a pass for a tree the copy did not run; building the copy from the tree itself closes it | inspection |
| 5 | P2 | A check that writes a tracked file now writes the copy, which is deleted unseen: the class goes from visible to invisible | inspection |
| 6 | P2 | The copy's `origin` is the checkout, so a push from the copy writes the real refs | reproduced |
| 7 | P2 | `owed.suite_links` rests on G6, marked inferred: no satellite declares `owed.suite`, and the two checks run needed no link; each link is a write path back into the checkout | live |
| 8 | P2 | A trap does not run on SIGKILL; removing the copy while a check's children run orphans them; nested runs and worktrees give the watched paths no meaning; `/var` and `/private/var` differ | theoretical |
| 9 | P2 | No acceptance row for the SKIP comparison, the recorded tree or the copy after the run; acceptance 2's probe could write the real home; the plan's `Lenses` section has no D3 line | inspection |

AMBIGUITY: F20's "no test writes this machine's real state" — (a) `suite.sh`
runs only; (b) every test a session runs, lane `verify` commands included;
code: (a).

Lenses that produced findings: the single test that breaks the design on day
one (1); a higher-level abstraction (2, the sandbox); every implicit state
machine (4, 8); the principal architect's rewrite (4, 5); concession drift
(7).

## Dispositions

No P0. Findings 1 and 3 were reproduced and 2 observed live, so no disprove
pass runs.

| # | Disposition |
|---|---|
| 1 | Adopted: `PLAYWRIGHT_BROWSERS_PATH` keeps the real folder beside the uv and npm caches, and acceptance 8 compares the SKIP lines with a run under the real home |
| 2 | Ruled by the operator on 2026-11-13, "Narrow check", over a macOS sandbox (`sandbox-exec`) that refuses writes outside the copy and over no check: only the checkout's `core.*` and `extensions.*` settings are compared, the class that once made the checkout bare. A breadcrumb keeps the sandbox for the day an escape is found |
| 3 | Adopted: `GIT_CONFIG_NOSYSTEM=1`, and `GH_TOKEN` and `GITHUB_TOKEN` unset |
| 4 | Adopted: the copy is the tree itself, read in with `git read-tree -u --reset`, its index then set to the real index's tree |
| 5 | Adopted: after the run the copy's tree must still be the recorded tree |
| 6 | Adopted: the copy's `origin` is removed |
| 7 | Adopted: no link list ships; G6 is now observed |
| 8 | Adopted: a fixed-prefix sweep at start, a process group stopped before removal, an absent value recorded as absent, git paths through `git config --local`, the scratch resolved with `pwd -P` |
| 9 | Adopted: acceptance 2 to 9 rewritten, and the `Lenses` section names D3 |
| AMBIGUITY | Settled as (a), the plan's own words, "the suite runs under"; a breadcrumb records lane `verify` commands as unisolated |

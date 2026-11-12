# Demo refresh: review round 1

Run `demo-refresh`, plan `docs/handoff/2026-11-13-demo-refresh.md`: lane
`script` (`demo/demo.sh`, `demo/README.md`, `fed7d0a..e9f3f2e`) and lane `page`
(the showcase page, its generator and its inventory check, `fed7d0a..a78fb81`).
One cross-functional reviewer (opus) read both lanes whole, statically; one QA
cell (sonnet) ran the plan's acceptance beside it.

## Code review

Decision 1 holds at the page tip: with the source panels stripped, exactly the
four framing placeholders remain. Every `#` link resolves, the HTML parses
balanced, the artifact variant equals the page's style and body, and each of
the 14 new manifest keys sits under the card of its name.

| # | Sev | Finding | Evidence | Disposition |
|---|---|---|---|---|
| 1 | P2 | The workloop card says a later commit makes `check` report `qa:stale`, and that `check` runs the composed test. `qa:stale` compares the QA record's tips with the lanes' tips, which move only on submit; a commit to a reviewed main-checkout lane reports `<lane>:moved-after-review`. `check` runs the composed test only for a one-writer run; parallel lanes are tested by `integrate` | inspection (`workloop_main.py:195-200`, `:296-297`) | Adopted (page) |
| 2 | P2 | The lede and the configuration heading say the hooks are carried by five hosts. Hooks are wired on Claude Code, Codex and Kimi; `.opencode/` holds generated permissions and instructions only, and Copilot reads instruction links | inspection (`.opencode/` holds `opencode.json` and `instructions/`, no plugin) | Adopted (page): three hosts run the hooks, two more read the same instructions |
| 3 | P2 | The guard-publish card's source panel embeds `guard-publish.sh`, whose header says it asks rather than denies; the card correctly says it denies where no prompt can show | inspection | Adopted (page): the panel maps to `.agents/hooks/lib/guard-publish.py`. The stale header in `guard-publish.sh`, a guard file and so Critical, is filed as a breadcrumb by the lead |
| 4 | P2 | The genome callout says the layer has its own runnable demo, `bash demo/demo.sh`; no beat shows it, and the README lists it as excluded | inspection | Adopted (page) |
| 5 | P2 | `demo.sh` builds `git`, `gh`, `npm` and `vercel` from variables, on a comment that the live guard reads a script it is asked to run. The publish guard reads a script only for a management-API host beside a write signal, and the script already carries `gh pr merge 1` literally | inspection (`hosted-scripts.py:12-20`) | Adopted (script): the variables go; the comment states the real constraint, that no probe names a hosting provider's management API |
| 6 | P2 | Beat 10's `gate` ends in `\|\| true` and serves the `check` that must pass; beats 7-9 print whatever returns. A regression leaves `bash demo/demo.sh` at exit 0 while it prints a wrong result | inspection | Adopted (script), widened to beats 4 and 5, which print FAIL and exit 0: each beat compares its result with the expected one, and the script exits 1 after the last beat when any did not match |
| 7 | P2 | The README says every workloop call carries `--state` and `--repo`; only `init` takes `--repo` | inspection | Adopted (script) |
| 8 | P2 | Plan table A rows 16 and 22 are half matched: the guard-destructive card omits `aws s3 rb --force`, the session-start card omits workloop runs with no recorded lead | inspection | Adopted (page) |
| 9 | P2 | "Triggers, not checklists" says the stop gate writes one status line. It sends the owed flags to the status strip and one message line, only when the flags changed | inspection (`session-wrap.sh:633-650`) | Adopted (page) |
| 10 | P2 | The hero map's breakdown, 14 + 7 + 2 + 5, sums to 28 against 27 policies: `ui-gate` has two cards and is counted twice. `check-inventory.py` checks only the total | inspection; present before the run | Adopted (page): `ui-gate` counted once, and `check-inventory.py` fails when the breakdown does not sum to the total |
| 11 | P2 | The scratch commits run a viewer's global git hooks, so a global pre-commit hook stops the demo midway | theoretical | Adopted (script): `-c core.hooksPath=/dev/null` in `g()` |
| 12 | P2 | `demo.sh` is 328 lines and builds a scratch repository three times by copy | inspection | Adopted in part (script): one scratch-repository helper. Beat 5's Python stays inline, accepted: the beats read top to bottom and a separate file buys no test |
| 13 | P2 | Beat 4's symlink count and broken-link sweep walk `.agents/worktrees/`, so lane worktrees inflate the count and a stale one prints FAIL | inspection; present before the run | Adopted (script), since the lane already edits beat 4: both read tracked links only |
| 14 | P2 | Three texts give three reasons the live guard lets the demo run: the beat 3 comment (the guard matches tokens), `demo/AGENTS.md` (payloads must be assembled at runtime, since a literal pattern trips the guard) and the README (payloads are assembled at runtime for that reason) | reproduced by the lead: the guard exits 2 on a typed `rm -Rf ~`, and 0 on `printf '{"command":"rm -Rf ~"}' \| guard-destructive.sh` and on `bash demo/demo.sh` | Adopted: the beat 3 comment is the true one. The script lane rewrites the README's "it's real" paragraph to it; the lead rewrites `demo/AGENTS.md`'s invariant at integration |

The reviewer's two ambiguities, coded as it read them and confirmed by the
lead: Decision 1 reserves the routing strip's three text slots, not the topic,
so the "Workflows and stakes" card stands; acceptance 1's `a:review` names
whatever the lane is called, `solo` in the script.

## QA

QA ran the plan's acceptance against both lane tips. Acceptance 1 to 3 passed.
Acceptance 7 failed:

| # | Sev | Finding | Evidence | Disposition |
|---|---|---|---|---|
| Q1 | P2 | At 390 px the page scrolls sideways: the hook and card grid items keep `min-width:auto`, so their no-wrap I/O lines and source panels widen them | reproduced; present before the run. The lead's live fix took the document from 971 px wide to 390 | Adopted (page): `.hooks{grid-template-columns:minmax(0,1fr)}` and `.hook,.card{min-width:0}` |
| Q2 | P2 | `demo.sh` prints colour codes with `NO_COLOR` set and when its output is not a terminal | reproduced by QA | Adopted (script) |

QA also saw a process-group warning from `revert-check.sh` in its own sandbox;
neither the lane's runs nor the lead's printed it.

Every finding is a P2, which the controller files rather than reopens, so both
lanes are accepted at their tips, `a78fb81` and `e9f3f2e`, and integrated. The
adopted fixes land as run `demo-refresh-r2`, branched from the merged result,
and its QA reruns the plan's whole acceptance over both runs. The page lane's
7,203 changed lines are mostly generated source panels.

# Round 2

Run `demo-refresh-r2`, branched from the round 1 merge at `f187496`: lane
`page` `f187496..14367ef` and lane `script` `f187496..be1ec59`. One reviewer
(opus) read both whole, statically; one QA cell (sonnet) ran the plan's
acceptance 1 to 8 and the run's 9 to 12 beside it.

## QA

Every item passed at both tips. The demo from `/tmp` exits 0 with the ten
beats' expected outcomes; four inversions of one beat's expectation, in beats
7, 9 and 10, each exit 1 with one `MISMATCH` line naming the beat. Piped and
`NO_COLOR` output carry no escape byte, and a terminal still gets colour.
Beat 4's link count does not move when a worktree holding a broken link
exists. At 1280 and 390 px the page's scroll width equals the viewport, with
every source panel open, no console message and no broken `#` link; exactly
the four framing placeholders remain; `embed-src.py` is idempotent. QA did not
run `check-all.sh` or `port-public.py check`; the lead runs both on the merged
commit.

## Code review

Every round 1 row is fixed except rows 6 and 14, which land in part. The
reviewer accepted the writers' choices: `ui-gate` counted once, as a gate;
`demo.sh` at 364 lines, the cost of row 6's result checks; beat 4 counting
tracked files.

| # | Sev | Finding | Evidence | Disposition |
|---|---|---|---|---|
| R1 | P2 | Several result checks cannot tell an error from the failure they expect. Beat 8 counts any non-zero `access.py` exit as the refusal; beat 9 counts `revert-check.sh`'s exit 1 for a scratch worktree it cannot create as a weak test; beat 10 compares exit codes only, and the last `check --recorded` exits 1 on `solo:review` whether or not `qa:stale` is raised; beat 6 reads any reply that is not JSON as REFUSED | inspection | Adopted: beat 8 matches the refused command's name, beat 9 the weak test's reason, beat 10 the expected blocker, and beat 6 reads REFUSED only from an explicit refusal |
| R2 | P2 | The README, `demo/AGENTS.md` and the beat 3 comment say `bash demo/demo.sh` passes the guard because it matches tokens, not text. The guard reads only the command line a session runs and opens no file it runs | reproduced by the lead: the guard exits 0 on `bash x.sh` whose body is a recursive force delete; `guard-destructive.py` opens no file | Adopted: the guard reads the command a session runs, not the files it runs, so `bash demo/demo.sh` passes; matching tokens is why a probe that hands it a destructive command as quoted data passes |
| R3 | P2 | `MISMATCH` lines go to stdout, which the run's composed test discards, so a failed `check` or `integrate` shows only the closing line, which names no beat | inspection | Adopted: `MISMATCH` lines go to stderr |
| R4 | P2 | `demo.sh` is 364 lines, and printing a coloured verdict exists in four copies | `wc -l` | Accepted: the growth is row 6's result checks |
| R5 | P2 | `check-inventory.py` takes a page path no caller passes, and a wrong path gives a traceback | inspection | Adopted: the argument goes |
| R6 | P2 | The breakdown check compares only the sum, so wrong figures that still add to 27 pass | inspection | Filed as a breadcrumb: deriving each figure from the cards' badges needs a precedence rule for hooks with two badges, which the page does not state |

Every finding is a P2, so both lanes are accepted at their tips and
integrated, and the lead applies R1, R2, R3 and R5 on `main`.

## The lead's fixes and their QA

R1 and R3 are `c0f391b`: each check in beats 6, 8, 9 and 10 also matches the
reason its outcome must print, read from the tools' own output (`access.py`
names the refused command, `revert-check.sh` says the test "does not catch the
defect", research-mcp marks a refusal `"failure": "policy"`), and `MISMATCH`
lines go to stderr. R2 is `9904307` with the beat 3 comment in `c0f391b`, R5
is `c3da32d`. `demo.sh` is 393 lines after R1. No reviewer read these three
commits.

A second QA cell (sonnet) ran at `f8c0aa2` and passed every item. The demo
exits 0 with no `MISMATCH` and leaves the checkout as it found it. Five
regressions, each made alone in a scratch clone and run with stdout
discarded, exit 1 with a `MISMATCH` line on stderr: a policy that does not
parse (beat 8), a `revert-check.sh` usage error (beat 9), a final check
blocked without `qa:stale` (beat 10), an MCP tool that does not exist (beat
6), and a flipped beat 3 expectation. The guard exits 2 on a typed recursive
delete and 0 on `bash <file>` holding it and on the same text as quoted data.
The lead rendered the merged page at 390 and 1280 px: the scroll width equals
the viewport, and the console holds no message.

Covers: fed7d0a..a78fb81
Covers: fed7d0a..e9f3f2e
Covers: f187496..14367ef
Covers: f187496..be1ec59

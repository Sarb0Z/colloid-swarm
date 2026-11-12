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

The page lane's 7,203 changed lines are mostly generated source panels; the
fix round stays in the lane.

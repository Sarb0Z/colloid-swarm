# Demo refresh: the terminal demo and the showcase page, brought to the current scaffold

Workflow: Build · Stakes: Standard. Asked by the operator on 2026-11-13: "can
you work on updating the demo as well, it is quite out of date I believe."

The demo is two artifacts. `demo/demo.sh` (with `demo/README.md`) runs the
scaffold's scripts live in six beats; it still runs, exit 0 from `/tmp`, and
stops at what existed in mid-October. `demo/scaffold-showcase.html` is a page
of hand-written cards, each with a "View source" panel that `demo/embed-src.py`
fills from the repository; `demo/check-inventory.py` keeps a card for every
hook and skill and the lede's counts true, and nothing checks the card prose.

## Findings

Read at `bdbd8c4` (the page audit, a read-only sonnet cell) and `fed7d0a` (the
lead's probes); `git diff --stat bdbd8c4 fed7d0a` over every cited path is
empty, and `git status --short -- demo` is clean. "L" is a line of the page with
every generated panel stripped (`<details class="src" data-gen="1">` removed),
which is how the audit read it; a writer finds the same text by searching for
the quote.

| # | Claim | Evidence | Status |
|---|---|---|---|
| F1 | `demo.sh` runs all six beats from `/tmp`, exit 0, in a few seconds | `bash demo/demo.sh` run from `/tmp`: every beat printed, exit 0 | observed |
| F2 | `demo/README.md` names a "reporter" persona; the file is `learning-reporter.md` | `ls .agents/personas` | observed |
| F3 | The README says six commands block and two pass; the script blocks seven and passes three | `demo.sh` beat 3 output | observed |
| F4 | The workloop controller takes `--state <file>`, so a beat can run it on a scratch repository without touching real runs; init, claim, commit, submit, check (blocked by `a:review, qa:missing, verified:missing`), review, qa, check (PASS), a later commit and submit, check (blocked by `a:review, qa:stale`) ran in 3 s | probe in `$TMPDIR/demo-audit/wl2` | observed |
| F5 | `revert-check.sh <base> --tests <t> -- <cmd>` on a scratch repository: exit 0 for a test that catches a reverted bug, exit 1 with "FAIL: … the test does not catch the defect" for a weak one, 1 s, no worktree left | probe in `$TMPDIR/demo-audit/rc` | observed |
| F6 | `guard-publish.sh` reads `{"tool_name","tool_input","permission_mode"}` on stdin and prints Claude's PreToolUse envelope: `ask` in default, acceptEdits and plan modes, `deny` in the others, silence on a quiet call | `.agents/test-guard-publish.py:218-262` | observed |
| F7 | `access.py check --repo <dir>` refuses a declared read the publish guard would ask about, by name: `` `gh pr merge 1` in system github, read: refused by guard-publish: `` | `.agents/test-access.sh:37-44` | observed |
| F8 | `embed-src.py`'s `MANIFEST` maps a card's visible name (a hook's `<span class="id">` or a card's `<h3>`) to the file its panel embeds | `demo/embed-src.py:26-30` | observed |
| F9 | The page's hand-written statements in table A below are false at `bdbd8c4` | each row's cited line, opened by the audit; rows 1, 7-9, 21 and 36 re-opened by the lead | observed |
| F10 | The page omits or barely describes the mechanisms in table B below | each row's path | observed |
| F11 | Ten bracketed placeholders sit in the page's copy (table C); earlier sessions left them as copy in the operator's voice (`4595bf5`, 2026-10-05; `99cbec7`, 2026-11-09) | `git log -S` | observed |
| F12 | Another session writes in this checkout and regenerates the showcase panels when its sources change; it staged a whole file this session was editing once (`a21f057`) | `git show --stat a21f057` | observed |

Re-opened by the lead: F9 rows 1, 7-9, 21, 36.

### A. Stale statements on the page

| # | Where | Page says | True at `bdbd8c4` |
|---|---|---|---|
| 1 | Hero lede L288 | "running unmodified under Claude and Kimi" | `README.md:3`: Claude Code, Codex, Kimi, OpenCode and GitHub Copilot |
| 2 | Config h2 L841 | "Two engines" | five hosts; Codex hooks in `.agents/codex/hooks.json` |
| 3 | Config flow, adapter.sh L849 | "Claude 114 lines · Kimi 36" | `.agents/claude/adapter.sh` 68, `.kimi/hooks/adapter.sh` 101, `.agents/codex/adapter.sh` 22 |
| 4 | Config flow, settings.json L847 | names no files | `.agents/claude/settings.json`, `.agents/codex/hooks.json`, `.kimi/config.toml.example` |
| 5 | Footer L900 | lists `.claude/`, `.kimi/` | also `.codex/`, `.opencode/` |
| 6 | Hero map, prompts & cells L296 | "18 files" | 17 cards in the section |
| 7 | Contract, Communication panel L337 | "beyond the ask is spam" | `AGENTS.md:133`: "Preserve decisions, evidence, risks, failures, and next actions; cut repetition and padding." |
| 8 | Same panel L338, L341 | "Candid always … never dressed up as done"; "Candor outranks brevity" | no such text in `AGENTS.md` or the output style |
| 9 | Same panel L339 | "Sources are the deliverable … one-line notes" | `AGENTS.md:133`: "Cite requested research." |
| 10 | Contract, When subagents fire L346 | "handed off as soon as it's identifiable" | `AGENTS.md:92`: delegation earns its cost chiefly on large units |
| 11 | Same panel L347 | plan and diff each get an attacker "once per slice (workflow steps 3 and 6)" | the Build table has no step numbers; code review is per delivered scope (`AGENTS.md:53`, `hostile-review.md:119`) |
| 12 | Same panel L348 | "trivia … goes to a smaller minion"; "a single tool call is never a delegation" | `AGENTS.md:92`: tiers by difficulty; neither phrase exists |
| 13 | Same panel L349 | "dense, distilled reports back, not transcripts" | `AGENTS.md:92`: "A handoff states decisions, paths, and one next step" |
| 14 | Contract, AGENTS.md card L368 | "everything above, verbatim" | the panels paraphrase (rows 7-13) |
| 15 | Contract, frontend.md card L371 | globs `*.tsx`, `*.css`, `*.html` | `.agents/rules/frontend.md:1-12` also jsx, vue, svelte, scss |
| 16 | Hooks, session-start L405 | breadcrumbs and the compaction policy | `session-start.sh:13-45`: also decisions, knowledge index, MCP and LSP state, workloop runs, worktree sweep, readouts, work log, the wrap baseline |
| 17 | Callout L891 | `genome-inject` "is omitted above" | its card is at L434 with a panel |
| 18 | Hooks, worktree-sessions L451-456 | under SubagentStart | `settings.json`: SessionStart and Pre/PostToolUse on EnterWorktree |
| 19 | Hooks, workloop-inbox L457-462 | under SubagentStart; a silent lane "is reaped" | also SubagentStop, UserPromptSubmit, PostToolBatch; only the lane's Docker resources are reaped, the lane waits for `release-stale` (`workloop-inbox.py:214-220`); it stamps each agent's last call (`workloop-inbox.sh:69-73`) |
| 20 | UserPromptSubmit group L412-428 | two hooks | three: research-prime, done-prime, workloop-inbox |
| 21 | Hooks, guard-destructive L471 | "The fail-closed floor" | `guard-destructive.sh:19-22` exits 0 when its library is missing; an unparseable payload exits 0 (`guard-destructive.py:1180-1182`) |
| 22 | Same card L471 | rm -rf, force-push, reset --hard, --no-verify, SSH, SQL | also `git clean -f`, rsync/scp to a remote, terraform destroy, `aws s3 rm --recursive`, `rb --force`, `kubectl delete` of a namespace or `--all`, `browser-sync.py`; SQL includes mariadb |
| 23 | Hooks, wait-gate L477 | main-agent `sleep` over 5 s | every agent (`wait-gate.py:9-10`); also unreadable sleeps and loops under a raised timeout |
| 24 | Hooks, guard-publish L483 | "asks rather than denies" | asks in default, acceptEdits, plan; denies elsewhere (`guard-publish.py:15-26`); also hosted migrations, Artifact actions, many `gh` writes; the push prompt names unreviewed critical-path files (`:493-500`) |
| 25 | Hooks, post-edit-check L531 | lints, formats, typechecks, exit 2 | two modes: `write` fixes and formats and exits 0 with context; `check` exits 2, async (`post-edit-check.sh:11-33`); a missing configured tool is reported once per session |
| 26 | Hooks, teardown-gate L585 | browser/device, server/watcher, container/emulator | also docker, build and worktree classes (`teardown-gate.sh:44-56`) |
| 27 | Hooks × model L636 | wrap emits a line naming checklists, read if the user opts in | on Claude: owed flags and one systemMessage, no question; the question stays on Codex and Kimi (`session-wrap.sh:615-617, 633-636`) |
| 28 | Hooks × model L641 | wrap blocks under the 8-block ceiling | on Claude it exits 0; the ceiling reasoning holds for Codex and Kimi (`session-wrap.sh:38-45`) |
| 29 | Skills, qa-verifier L696 | after the implementation tests and before final review | beside the code review, briefed with the ask, acceptance and test suite, never the diff; reads the environment log through `access.py logs` (`qa-verifier/SKILL.md:7-9`, `AGENTS.md:52`) |
| 30 | Skills, workloop L690 | parallel lanes as the point | the skill first picks a shape, one writer by default (`workloop/SKILL.md:3, 13-52`) |
| 31 | Prompts, researcher.md L771 | "WebSearch → WebFetch → context7 → playwright" | WebSearch, WebFetch, context7, research-mcp; no playwright (`personas/researcher.md:4-6, 15-18`) |
| 32 | Prompts, hostile-review.md L777 | "no justifying"; "severity floor"; "steps 3 and 6" | "No praise, filler, or invented findings" (`:18-20`); a theoretical finding must not exceed P2, a ceiling (`:62-63`); no step numbers |
| 33 | Prompts, breadcrumb-burndown.md L795 | acted on, refiled, or deleted | Fix now, Convert, Delete, Escalate (`breadcrumb-burndown.md:25-30`) |
| 34 | Tracking, discovered subprojects L830 | "<15 min, file open → inline" | "fix inline only when trivial and already open" (`AGENTS.md:118`) |
| 35 | Tracking, breadcrumbs.md L818 | at the top of every session | every open decision and the 10 newest entries, after the style, drift, workloop and worktree sections (`session-start.sh:347-363`); 40-word cap |
| 36 | Config table L864-865 | `subagents.researcher.model`, `.tools` | no `subagents` key; the pin is the persona's frontmatter |
| 37 | Config table L858 | `session_wrap.trivial` | `trivial_files: 2`, `trivial_lines: 30` |
| 38 | Config table L859 | `session_wrap.large` | `review_files: 5`, `review_lines: 150`, plus `heavy_tool_calls: 60` |
| 39 | Config table L857 | every hook `enabled: true` | `worktree_sessions`, `product_folder`, `worklog`, `learning_report` default false |
| 40 | Config card L875, map L298 | one committed file; environment variables override | `config.json.example` (defaults) and `policy.json` (tracked) are committed, `config.json` is the ignored override (`.agents/AGENTS.md:16`); only `session_wrap` thresholds read `WRAP_*` |

### B. Mechanisms the page omits or under-describes

| # | Mechanism | Path |
|---|---|---|
| 1 | Workloop controller: lanes, cells, `check`, QA bound to lane tips (`qa:stale`), integrate, teardown | `.agents/workloop.py`, `workloop_*.py`, `.agents/skills/workloop/` |
| 2 | Delegation shapes and the tier map (light haiku, medium sonnet, heavy opus, frontier fable) | `skills/workloop/SKILL.md:13-52`, `claude/delegation.md:10-13` |
| 3 | Status strip and readouts | `claude/statusline.sh`, `hooks/lib/readout.py` |
| 4 | Owed-work flags (review, suite, report, worklog, cleanup, learning) and review records' `Covers:` lines | `hooks/lib/owed.py`, `policy.json` `owed` |
| 5 | The check list and its runner | `check-all.sh`, `suite.sh`, `lint-suite.py` |
| 6 | Declared systems and their read-only access | `access.py`, `policy.json` `systems` |
| 7 | A fix's test proven to catch the defect | `revert-check.sh` |
| 8 | The review harness that grades the shipped reviewer contract | `.agents/eval/review-harness/` |
| 9 | Plan research and the `Acceptance:` block | `playbooks/plan-research.md`, `AGENTS.md:46-47` |
| 10 | The disprove pass and the review records | `playbooks/hostile-review.md:92-100, 126-142` |
| 11 | The ten workflows and three stakes levels | `AGENTS.md:26-39`; the Routing strip is placeholders (C) |
| 12 | Human gates and `needs_confirmation` | `AGENTS.md:77-79` |
| 13 | Hook events missing from the page: SubagentStop, PostToolBatch, PostToolUseFailure, StopFailure | `claude/settings.json` |
| 14 | Durable stores beyond two ledgers: `decisions.md`, `knowledge/` | `AGENTS.md:118`, `session-start.sh:139-149` |
| 15 | The MCP registry and the two repository-owned servers | `mcp.json`, `mcp.py`, `mcp-servers/` |
| 16 | Export and transplant | `export-scaffold.py`, `export/merge-kit.py` |
| 17 | Device policy and the publish-approval mod | `claude/device/`, `claude/mods/publish-approval` |
| 18 | The output style as an artifact | `claude/output-style.md` |

### C. Placeholders in the page's copy

L292 `[Contract menu line — one line]`; L318 `[Routing strip title — one line]`
and `[Routing strip — how a task gets its workflow and stakes, one or two
sentences]`; L320 `[Routing note — …]`; L489 `[keychain-notice card — …]`;
L495 `[denied-tool card — …]`; L714 `[diagnosing-bugs card — …]`; L720
`[grilling card — …]`; L723 `[grill-me card — …]`; L726 `[domain-modeling card
— …]`.

**Constraints.** Every beat shows live output of the real scripts (`demo/AGENTS.md`);
`demo.sh` resolves the repository from its own path; the inventory check stays
green (F8); the other session's writes in this checkout (F12) mean each writer
works in its own worktree.

**Open questions.** None; who writes card text was Decision 1 below.

## Plan

Two lanes of one workloop run, `demo-refresh`, each in its own worktree, on
disjoint files; the lead integrates, regenerates and verifies once.

**Lane `script`** owns `demo/demo.sh`, `demo/README.md`. Four beats join the six,
each live, offline, needing only `bash`, `python3` and `git`. One `EXIT` trap,
set at the top of the script, removes every scratch folder the run makes, the
export kit included; no beat sets a trap of its own. Every scratch commit runs
as `git -c user.name=demo -c user.email=demo@example.invalid -c
commit.gpgsign=false`, so a viewer's git identity or signing setup cannot stop
the demo.

- **The publish guard.** `guard-publish.sh` on runtime-assembled payloads in
  `default` mode: `git push origin main`, `gh pr merge 12`, `npm publish` and
  `vercel deploy --prod` print ASK with the guard's full reason; `git status`
  and `gh pr view 12` stay quiet; the push again in `auto` mode prints DENY
  (F6). The payload's `cwd` is a scratch git repository with one commit and no
  remote, so the push reason describes that repository, not this one. No probe
  names a hosting provider's management API, since the live guard reads
  `demo.sh` itself when a session runs it. The guard reads this checkout's
  `hooks.guard_publish.enabled` and prunes expired approval tokens from its
  `.agents/`; the README says so.
- **Declared read access.** Two live `access.py check --repo` calls on scratch
  folders: one whose `.agents/policy.json` declares `gh pr list` and `gh pr
  merge 1` as reads of a system `github`, refused with the merge named (F7);
  one that declares only `gh pr list`, which prints "systems: 1 declared, every
  command passes the guards". `check` prints its summary only when nothing
  fails (`access.py:181-194`), hence two calls.
- **A test that catches its bug.** A scratch repository with a bug, its fix,
  a test that asserts the result and one that only imports; `revert-check.sh`,
  run from inside that repository, passes the first and fails the second (F5).
- **The completion gate.** Every workloop call takes `--state <scratch file>`,
  and `init` takes `--repo <scratch repository>`, so nothing lands in this
  checkout's `.agents/worktrees/` or `.agents/.readout/`. One lane is claimed,
  committed and submitted, and `check --recorded` names what blocks
  completion; after review and QA, `check` passes; a later commit and resubmit
  make `check --recorded` report `a:review, qa:stale` (F4), since a lane's tip
  moves only on submit.

The banner and header comment name the ten beats. Every existing beat title,
header comment and README sentence is checked against table A rows 1-5 and
21-22: beat 3 loses "fail-closed floor", the README names the three hosts that
wire `guard-destructive` (Claude, Codex, Kimi) and every host folder, and beat
4 counts links under `.codex`, `.opencode` and `.kimi` too. The README lists
each beat (`demo/AGENTS.md` keeps no copy of that list), names the personas by
their files, and states no count the output can contradict (F2, F3). Node
stays needed only for the MCP beat. `demo.sh` is 196 lines; past 300 the lane
reports it.

**Lane `page`** owns `demo/scaffold-showcase.html`,
`demo/scaffold-showcase.artifact.html` (rewritten only by `embed-src.py`),
`demo/embed-src.py` and, if a new card class needs it,
`demo/check-inventory.py`. It rewrites every row
of table A to match its cited source; the four contract panels quote
`AGENTS.md` word for word, short excerpts, so the "verbatim" card is true. It
adds cards or card text for table B rows 1-14 and 16, inside the existing
seven sections; rows 15, 17 and 18 get a sentence in the card that already
touches them. Each new card whose subject is one file gets a `MANIFEST` entry
and so a source panel. Hook cards sit under the events `settings.json` wires
them to. Card text follows Decision 1. The artifact variant is regenerated by
`embed-src.py`, never edited.

The run's composed test (`--verify`) is `bash demo/demo.sh >/dev/null &&
python3 demo/check-inventory.py`.

**Lead, at integration.** `integrate` merges both lanes onto `main` in its own
worktree. If the other session regenerated the page's panels meanwhile and the
merge conflicts in `scaffold-showcase.html`, the lane's hand-written text wins
and `embed-src.py` rebuilds every panel. After the `--no-ff` merge to `main`:
`python3 demo/embed-src.py` and `python3 .agents/port-public.py refresh`,
committing only the demo files and the public tree's two page files, and a
change refresh makes to another starter in a commit of its own. The checks
run in a clean clone of the merged commit, since the main checkout holds
another session's uncommitted files. A `debt-log.md` entry,
`showcase-prose-unchecked`, records that nothing checks card prose against its
source, with a `debt:` pointer in `check-inventory.py`'s docstring.

**QA.** A `qa-verifier` cell, briefed with the ask and this Acceptance block,
reproduces Acceptance 1 and 2 from a clean shell and Acceptance 7 in a
browser, beside the code review. The final message carries the feedback
checkpoint: the command, numbered steps with expected values, known gaps, and
what the agent did not check.

**Decision 1, ruled by the operator on 2026-11-13: (a).** The agent writes
every card body from what its code does, the six card placeholders of table C
included (keychain-notice, denied-tool, diagnosing-bugs, grilling, grill-me,
domain-modeling), in the page's current plain tone. The four framing lines,
the hero menu's contract line and the Routing strip's title, body and note,
stay placeholders for the operator. Declined: (b) facts only, every new card
line a placeholder; (c) the agent drafts the framing lines too.

**Seams under test.**
- `demo.sh` run from `/tmp`, end to end: catches a beat that fails, prints
  canned text, or leaves a scratch folder, worktree or state change behind;
  misses how a beat reads to a viewer.
- `check-inventory.py`: catches a hook or skill with no card and wrong lede
  counts; misses false prose.
- `embed-src.py` twice: catches a manifest key with no card and a non-idempotent
  rewrite; misses a panel under the wrong card.
- The page in a browser at 1280 px and 390 px: catches broken layout, console
  errors and dead in-page anchors; misses wrong facts, which the review reads
  against table A.

## Acceptance

1. `cd /tmp && bash <repo>/demo/demo.sh` exits 0 and prints ten beats. Beat
   by beat: ASK on `git push origin main`, `gh pr merge 12`, `npm publish` and
   `vercel deploy --prod`, quiet on `git status` and `gh pr view 12`, DENY on
   the push in `auto` mode; `gh pr merge 1` refused by name, and the policy
   with only `gh pr list` printing "systems: 1 declared, every command passes
   the guards"; the asserting test passes revert-check and the import-only
   test fails it; `check --recorded` blocked, then `check` PASS, then
   `check --recorded` blocked by `a:review, qa:stale`.
2. After that run, `git -C <repo> status --short`, `git -C <repo> status
   --short --ignored -- .agents/worktrees .agents/.readout` and `git -C <repo>
   worktree list` are unchanged, and no folder the run made remains under
   `$TMPDIR`.
3. `demo/README.md` names each file in `.agents/personas` and each of the ten
   beats, and holds no count the script prints; no sentence in `demo.sh` or
   `demo/README.md` contradicts a row of table A.
4. Each row of table A matches its cited source on the page, or the review
   record lists it as declined with a reason.
5. Table B rows 1-14 and 16 each have a card or card text; each new
   single-file card has a source panel.
6. `python3 demo/check-inventory.py`, `python3 demo/embed-src.py` run twice
   with no diff after the first, `python3 .agents/port-public.py check` and
   `.agents/check-all.sh` pass.
7. The page renders at 1280 px and 390 px with no console error and every
   `href="#…"` resolving to an element.
8. With every generated panel stripped, the page holds exactly four matches of
   `\[[^]]+ — [^]]+\]`, the framing lines of Decision 1, and the final message
   lists them with their lines as one question.

## Lenses

- Higher-level abstraction: the card prose drifts because nothing checks it;
  generating it from the sources would end the drift but turns a showcase into
  a reference dump. Not now; `debt-log.md` records the class
  (`showcase-prose-unchecked`).
- Irreducible constraints: live output, offline, no state left behind; a card
  says only what its source says.
- Carve at the joints: script and page are disjoint files and audiences, so two
  lanes.
- Principal architect's rewrite: n/a; the page's structure holds the new cards.
- Implicit state machines: the workloop beat walks the run's lane states
  (ready, active, review, reviewed) and the QA record's freshness.
- Concession drift: n/a.

## Review

Round 1, one reviewer (opus), on the plan with Decision 1 ruled: two `P1`,
eleven `P2`, every one adopted into the text above.

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | `access.py check` never prints a pass for `gh pr list` while the merge fails, so the beat would need canned text | Two live calls; Acceptance 1 names the summary line |
| 2 | P1 | The script lane re-audits no existing beat or README sentence, so "fail-closed floor", "both engines" and the two host folders survive in the terminal demo | Checked against table A rows 1-5 and 21-22; Acceptance 3 extended |
| 3 | P2 | A commit without a resubmit leaves the lane's tip, so `check` stays PASS | "a later commit and resubmit" |
| 4 | P2 | `init` without `--repo` binds the run to this checkout; `check` writes ignored paths `git status` cannot see | `--repo` and `--state` on scratch; Acceptance 2 reads the ignored paths |
| 5 | P2 | The existing trap removes only the export kit, and a second trap replaces it | One trap at the top for every scratch path |
| 6 | P2 | A `cwd` that is not a repository makes the push reason a review-state error, hidden by printing one sentence | A scratch repository with one commit; the full reason printed; the README names the guard's reads of this checkout |
| 7 | P2 | A deploy probe written as a management-API call makes the live guard read `demo.sh` and ask on running the demo | `vercel deploy --prod`, and no management-API probe |
| 8 | P2 | A viewer with no git identity or with commit signing on stops at the first scratch commit | `git -c` identity and `commit.gpgsign=false` |
| 9 | P2 | The embedded `AGENTS.md` panel quotes a bracketed placeholder, so a full-page count is wrong | Counted with panels stripped, by a named pattern |
| 10 | P2 | `embed-src.py` rewrites the artifact variant no lane owned, and the plan named no composed test | The page lane owns it; `--verify` named |
| 11 | P2 | A concurrent panel regeneration can conflict, refresh can carry an unrelated starter, and the main checkout holds another session's uncommitted files | Conflict rule, separate commit, checks in a clean clone |
| 12 | P2 | The drift class recorded only in a review record goes unfiled | `debt-log.md` entry `showcase-prose-unchecked` |
| 13 | P2 | No QA claim and no feedback checkpoint | A QA paragraph and the final message's checkpoint |

The reviewer's ambiguity, `demo/AGENTS.md`'s "Do not restate the beat
descriptions in `demo/README.md`": read as the scaffold file keeping no copy of
the README's beat list, which the current files and the plan follow.

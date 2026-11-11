# Scrapling unit 3: code review round 1

Unit 3 of `docs/handoff/2026-11-11-scrapling-review-fixes.md`: the host-trigger
check in `.agents/test-teardown-gate.sh`, which asserts that each host's hook
matcher lets through the tool names the teardown gate (which records what a
session opens and blocks Stop until each is closed) classifies. Commit
`5c073f2` on `01d56bb`, lane `u3` of run `scrapling-u3`. Two reviewers, one axis
each: how the test models the hosts and the gate (sonnet), and whether it
catches what it claims, by 91 mutants through the whole script (sonnet).

## Findings

| # | Sev | Finding | Evidence |
|---|---|---|---|
| A1 | P2 | Kimi's teardown PostToolUse matcher omits Kimi's `TaskStop`, which the gate classifies as a stop: a server stopped that way blocks Stop once, falsely; `native["kimi"]` mirrors the matcher, not the gate | inspection, Kimi's tool docs |
| A2 | P2 | The tool list holds two of the four names `APPIUM_BOOT` accepts; a host matcher narrowed to those two stays green | reproduced |
| A3 | P2 | `re.compile(r"^" + r"mcp__…")` and a raw string used through `re.search` pass the count check unread | reproduced |
| A4 | P2 | Claude's PreToolUse matcher `Bash\|EnterWorktree` omits `PowerShell`, so a worktree made through PowerShell is never snapshotted and never recorded | reproduced |
| A5 | P2 | A comment containing `re.compile(` fails the count check falsely | reproduced |
| A6 | P2 | A `*`, empty, comma-list or missing matcher, each valid on at least one host, gives a false red; `*` crashes the check | reproduced |
| B1 | P1 | The pass message "every host trigger matches every tool name the gate classifies" is false: a new alternative inside an existing gate regex (`APPIUM_CLOSE` + `stop_session`, `BROWSER_OPEN` + `snapshot`, `CLOSE_SESSION` + `browser_stop`, `APPIUM_BOOT` + `prepare_android_emulator`) or a new name in `STOP_TOOL` (`KillTask`) stays green with no host change | reproduced, through the whole script |
| B2 | P2 | An `_rc = re.compile` alias, `re.compile (` with a space, an inline `re.match(r"…", tool)` and `tool.endswith(…)` hide a regex from the count | reproduced |
| B3 | P2 | A verbose pattern compiled with `re.X` is read without the flag and fails falsely | reproduced |
| B4 | P2 | A group with no `matcher` key, match-all on every host, is skipped and fails falsely | reproduced |
| B5 | P2 | No listed server name holds an underscore; narrowing the server segment to `[A-Za-z0-9-]+` stays green | reproduced |

AMBIGUITY: unit 3's "assert every MCP regex the gate compiles matches at least
one listed name" — (a) that check is the whole requirement; (b) the test must
also fail when a host stops accepting a name the gate classifies; code: a.

Held, with evidence: Claude Code reads a matcher of letters, digits, `_`, `-`,
spaces, `,` and `|` as exact names and anything else as an unanchored regex;
Kimi's matcher is a regex with no stated anchoring; `re.fullmatch` is the same
as or stricter than every host, so the check never passes a name a host would
skip. The adapters pass `tool_name` through unrenamed. Every group that runs
the gate is found, and `.kimi/` removed passes.

## Review of the review

A third cell (opus), given the artifact and the claims, reproduced each in a
scratch clone, B1 through the whole script.

- **Every finding is supported**; A6 in part: Codex documents `*`, empty and a
  missing matcher, not comma lists, and does not document exact-name mode.
- **B1 is P2, not P1**: it is plan finding T2's class, rated P2, and loses one
  tool name only after a future gate edit. Only its two open-side mutants
  leave a resource that never blocks Stop; the three close-side ones cause a
  false block. The pass message is false either way.
- **A1 recurs**: it is an open breadcrumb, and the plan's own "Codex and Kimi
  `Bash`" carried the gap.
- **B5 is credible**: Claude Code names plugin servers
  `mcp__plugin_<plugin>_<server>__<tool>`, underscores included.
- The ambiguity is valid; (b) is what T2 asks for and what the unit's title,
  "the trigger test checks what it claims", promises.

It named two gaps:

| # | Sev | Finding |
|---|---|---|
| G1 | P1 | No suite asserts the gate's Stop and SubagentStop registration: with `teardown-gate.sh` removed from both in Claude's settings, the gate records and never blocks, and every suite that reads the settings stays green (reproduced) |
| G2 | P2 | `tool == "Monitor"` and `tool == "EnterWorktree"` classify without a regex, so the reader never sees them; `tool in ("Monitor", "Watch")` stays green (reproduced) |

It measured four ways to list the names a gate regex accepts without the
private `re._parser`. A 30-line expander for the grammar the gate uses (literal
characters, anchors, groups, `?` on a group, the one server class, and an error
on anything else) agreed with `re._parser` on all nine regexes, expanded
`APPIUM_BOOT` to its four names, and turned B1's five mutants, A2 and B5 red.
Adding a reader of the gate's Python heredoc through `ast`, which lists every
expression that reads `tool` and flags any form it cannot read, also turned
A3, B2 and G2 red, read `re.X` as an argument, and stopped A5's false red;
about 70 lines, test only.

## Dispositions

G1 blocks, so the lane is reopened at P1; the adopted P2s are fixed in the same
correction, which trails `5c073f2`.

| # | Disposition |
|---|---|
| G1 | Adopted: the check asserts that Stop runs the gate on every host, and SubagentStop on Claude |
| B1 | Adopted at P2, settling the ambiguity as (b), since plan finding T2 asks that a gate class with no host trigger goes red: every name each gate regex accepts, enumerated by the expander, must pass each host's PostToolUse matchers, and the pass message says what is checked |
| A2, B5 | Adopted with B1: the expansion covers every boot name; the sample server name holds an underscore |
| A3, B2, G2, A5, B3 | Adopted: the `ast` reader of the gate's heredoc replaces the text count, fails on any expression reading `tool` that it cannot read, and compiles each pattern with the flags its call passes |
| A6, B4 | Adopted: a missing, empty or `*` matcher counts as matching every name |
| A1 | Breadcrumb, sharpened: the existing line now carries the evidence that Kimi documents `TaskStop`; the fix edits `.kimi/config.toml.example`, outside this test-only unit |
| A4 | Breadcrumb: `PowerShell` in Claude's PreToolUse teardown matcher, a settings change outside this unit |

## The correction

`a0076bb` lands the adopted rows in the test alone. Its implementer ran ten
mutants through the whole script, and each went red on its own line. They
covered: Stop and SubagentStop removed, B1's open-side and stop mutants, the
narrowed boot alternative, the narrowed server segment, a concatenated
pattern, a `re.compile` alias, and `tool in ("Monitor", "Watch")`. The two
controls stayed green: A5's comment, and `.kimi/` removed. The lead reran the
script as committed (exit 0) and with Claude's Stop group removed (exit 1,
`claude: no Stop group runs teardown-gate`). The fix settles a `P1` inside the
subsystem this round reviewed, so it does not re-enter review.

The run's composed test failed at the lane's tip on one step outside the lane:
`port-public.py check` found the demo starters stale, from another session's
`3b4392f` beneath the tip. Two commits regenerated the starters: `f085ef5` for
`3b4392f`, and `f0da423` for `53ce23e`, which landed meanwhile. The composed
test passed at `f0da423`, and the run was closed with `abandon`, since `check`
verifies only at the tip.

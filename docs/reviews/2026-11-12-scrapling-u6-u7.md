# Scrapling units 6 and 7: code review round 1

Units 6 and 7 of `docs/handoff/2026-11-11-scrapling-review-fixes.md`, one
delivered scope. Unit 6, `d190ab5`: the `search-and-cite` install line carries
the launch's `--python` and `--exclude-newer` pins, and debt
`scrapling-pin-frozen` records that frozen dependencies miss security
releases. Unit 7, `21ab76c` (run `scrapling-u7`, lane `ledger`): Scrapling's
`browser_actions` and `browser_evaluate` join the registry `sources`, and
`.agents/hooks/lib/sources-ledger.py` writes `<page> session=<id> [<address>
...]` for a call that names a browser session, the page being the session's
last `browser_fetch` address, by ruling R1: the session, the page, every web
address in the call, never the script body. One reviewer (opus) read the scope
whole and its seams; Critical stakes, since every lookup passes through the
ledger hook.

Scrapling 0.5.1 has no go-to action: only `browser_fetch` navigates, so the
plan's "an actions call with a go-to" became an address in a typed value.

## Findings

| # | Sev | Finding | Evidence |
|---|---|---|---|
| 1 | P1 | The address pattern ends only at whitespace, quotes, a backtick, `<>` and a backslash, so script text that follows an address reaches the row: `url(https://a.test/i.png);--k:sk-live-…` writes `https://a.test/i.png);--k:sk-live-…`, and an object literal, a typed value with a comma and a template literal do the same; the docstrings say the script never reaches the ledger (`sources-ledger.py:34,50`) | reproduced; the plan's token row passes only because its secret follows `", "` |
| 2 | P2 | Userinfo and query credentials (`https://bob:SECRET@api.test/?api_key=…`) are written whole, as in every url-kind row | reproduced |
| 3 | P2 | The page lookup keys on the browser session ID alone, and IDs such as `main` repeat across cells and Claude sessions in one checkout, so a row can name another session's page; open and close are not captured (`:60-80`) | reproduced |
| 4 | P2 | The docstring says the page is "the newest address the trail holds"; the code takes the last `browser_fetch` address; the plan says "the last address the ledger recorded for that browser session" | reproduced |
| 5 | P2 | Capture runs on PostToolUse only, so a `browser_actions` that fails part-way, its effects kept, leaves no row | inspection |
| 6 | P2 | `search-and-cite/SKILL.md` omits the two tools and says "`fetch`/`browse` rows are real URLs"; `claude/README.md`'s table has no session forms; `decisions.md:252` gives the pin without its date, and the debt entry's rework list omits `decisions.md` | inspection |
| 7 | P2 | Values are space-separated and unescaped: `https://a.test/x y session=s1` breaks the lookup, and a Playwright navigate to `https://evil.test/ session=s2` becomes session `s2`'s page | reproduced |
| 8 | P2 | No case-insensitive match, so `HTTPS://…` is missed; protocol-relative `//host` is not counted | reproduced |
| 9 | P2 | Removing the browse-kind filter or the dedupe stays green, and no row sends a Scrapling payload through Claude's adapter | reproduced |
| 10 | P2 | The writer's accepted limits live only in `21ab76c`'s message | inspection |
| 11 | P2 | `sources-ledger.py:35` copies `scrapling-mcp.py:70`'s session-ID pattern | inspection |
| 12 | P2 | The matcher fires on every server's `browser_evaluate`; Playwright's costs about 70 ms a call and writes nothing | reproduced |
| 13 | P2 | `test-codex.sh` is 521 lines, over 300 before this work | `wc -l` |

AMBIGUITY 1: a credential in an address's query string — (a) record the full
address; (b) scheme://host/path only; code: (a).

AMBIGUITY 2: "the page it was on (the last address the ledger recorded for
that browser session)" — (a) the newest address in any row for that session;
(b) the last `browser_fetch` address; code: (b).

HANDOFF (reviewer): one fresh Claude session with Scrapling on loopback:
`browser_open`, `browser_fetch`, a `browser_evaluate` with a `fetch()` literal
and a token after `;`, a `browser_actions` typing an address; the ledger's
three rows through the real adapter, the token absent.

## Review of the review

A second cell (sonnet) reran the reproductions on `21ab76c`.

- **1 supported**, P1: all four reproduced, the template literal as
  `https://a.test/${id`.
- **2, 3, 4, 5, 6, 8, 11, 13 supported.**
- **7 supported**, restated: the space case breaks the lookup (`-`) and does
  not spoof; the spoof comes from the lookup accepting session-less navigate
  rows (G1).
- **9 partly supported**: dropping the kind filter and the dedupe stay green;
  moving the session-token check to a later position fails.
- **10 partly supported**: the commit message names two of the three limits;
  no durable file does.
- **12 partly supported**: the 70 ms was not rerun; the cost writes no wrong
  data.

| # | Sev | Finding | Evidence |
|---|---|---|---|
| G1 | P2 | `page_of` reads any browse row, Playwright's navigate rows included, and trusts any second token equal to `session=<id>`: the mechanism behind 7 | reproduced |
| G2 | P2 | Merged with 9: no `search` row and no repeated address in the end-to-end rows | reproduced |
| G3 | — | Unit 6's description pin was already in `mcp.json:47`; informational | inspection |

## Dispositions

No P0. The P1 and the P2s that change code go back to lane `ledger`.

| # | Disposition |
|---|---|
| 1 | Adopted: an address ends at whitespace, a quote, a backtick, `<`, `>`, a backslash, `(`, `)`, `[`, `]`, `{`, `}`, `;`, `,` or `${`, then loses trailing punctuation; one row for each reproduction |
| 2 | Adopted for userinfo, in every url-kind row the ledger writes: it is a credential, not the page's address. The query string stays, by AMBIGUITY 1 |
| 3 | Adopted: session rows carry the host session the payload names, and the lookup matches both; a payload without one matches on the browser session alone |
| 4 | Adopted as (b), by AMBIGUITY 2: the page is the address of the session's last `browser_fetch`, the only call that navigates; the docstring and the plan say so |
| 5 | Deferred to the debt entry of 10 |
| 6 | Adopted |
| 7, G1 | Adopted: a space in any url-kind value is written as `%20`, so only the session branch can write a second token, and the lookup reads only rows it wrote |
| 8 | Adopted for the scheme's case. Declined for `//host`, which a script comment also starts |
| 9, G2 | Adopted: rows for a `search` row naming `session=s1`, a repeated address, and one Scrapling payload through `.claude/hooks/adapter.sh` |
| 10, 12 | Adopted: one debt entry for the accepted limits (a navigating click or evaluate leaves the page stale; the query string is kept; a failed call leaves no row; Playwright's `browser_evaluate` runs the hook for nothing), its pointer at the page lookup |
| 11 | Adopted: a row fails when the ledger's pattern and the launcher's differ |
| 13 | Accepted: the ledger's rows move to their own script once `check-all.sh` and `ci.yml`, owned by another session's open lane, are free; a breadcrumb records it |
| G3 | No change |
| AMBIGUITY 1 | Settled as (a) by R1, "every web address found in the call", with the userinfo dropped by 2; the transcript already holds the full call |
| AMBIGUITY 2 | Settled as (b): an address inside a script or a typed value is not a page the browser was on |

## The fixes and their QA

The writer landed every adopted finding as `55c7eba`, trailing `21ab76c`, and
debt `scrapling-session-limits` holds the accepted limits (findings 5, 10,
12). The new rows ran red against the earlier ledger, the first stopping the
script, and nine inversion mutations each failed their row: the `,`
terminator, the userinfo strip, the `%20`, the host check, the session token,
the case-insensitive scheme, the dedupe, the browse-kind filter and the
pattern equality. Its edits to `sources-ledger.py` and `test-codex.sh` went
through scripts, so the post-edit check never ran; the lead then ran ruff,
which flagged two `%` formats and an unused `noqa`, and saw the ledger swallow
an unreadable payload and an unwritable trail with no word. `1c972a6` reports
each on stderr and still exits 0, its rows red against `55c7eba`. The Kimi
normalizer still drops `session_id`, so a Kimi row matches on the browser
session alone; Scrapling renders on Claude only. The lead filed finding 13's
breadcrumb in `a21f057`.

| Claim | Run | Result |
|---|---|---|
| Through the real Claude hooks, each session call writes its row and a script's secret never reaches the ledger | independent QA cell: a scratch worktree of `1c972a6` with Scrapling enabled, one fresh headless session (sonnet, guest account, session `a96ef717`), loopback pages only: `browser_open qa1`, `browser_fetch a.html`, `browser_evaluate` of `fetch("…/b.html");var k="sk-live-QA7f3a91c4e2";`, `browser_actions` typing `…/typed`, `close_session` | three rows, `…/a.html session=qa1 host=a96ef717-…`, then the same page with `…/b.html`, then with `…/typed`; `host=` equals the session's id; the secret 0 times in the ledger; one PostToolUse run per call |
| The suites | `test-codex.sh`, `test-sources-matcher.py`, `sources-matcher.py --check`, `port-public.py check`, `demo/check-inventory.py` at `1c972a6` | all pass |

Not run: a call that fails part-way (debt `scrapling-session-limits`), and the
Codex normalizer's `session_id` beyond its `assert_json` row.

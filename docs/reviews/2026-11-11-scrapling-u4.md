# Scrapling unit 4: code review round 1

Unit 4 of `docs/handoff/2026-11-11-scrapling-review-fixes.md`: Scrapling's
five denied tools get remedies in `.agents/hooks/lib/denied-tools.json`, which
`denied-tool.sh` prints to the model after a denial, their names in that hook's
matcher in `.agents/claude/settings.json`, and rows in `test-permissions.sh`'s
`REQUIRED_DENY`. Commit `3c20027` on `1a2591e`, lane `u4` of run
`scrapling-u4`. Two reviewers, one axis each: the rules and their test
(sonnet), the remedy text (sonnet).

## Findings

The rules reviewer found none: the matcher fires for exactly the six names,
and thirty mutations (a name dropped from the matcher, a remedy deleted, a deny
misspelt or removed, an `instead` removed, each for every name) all went red.

| # | Sev | Finding | Evidence |
|---|---|---|---|
| R1 | P2 | The `browser_save_state` and `browser_load_state` remedies say nothing needs saving or loading, which is false across sessions: a login ends with `close_session`, and the remedy's "carry on" never routes a model without the operator's login to the question the access-restriction ruling asks | inspection |
| R2 | P2 | The three raw-HTTP remedies send a plain request straight to the stealth browser, the slowest tier, skipping `WebFetch`, `fetch_readable` and a script, and offer nothing for a POST or JSON body | inspection |
| R3 | P2 | No remedy says `browser_open` needs a `session_id` the model picks and passes to `browser_fetch` and `close_session`; bare `close_session` also names an Appium tool | inspection |
| R4 | P2 | "Several pages from one site" is a limit neither the code nor the ruling imposes, and the 25-page bound is not named | inspection |
| R5 | P2 | "Reaches no address guard and no source ledger" names two repository mechanisms a cold reader cannot place | inspection |
| R6 | P2 | `open_request_session`'s `why` says it fetches, which `session_make_request` does; the two state remedies open with a noun, not an action | inspection |

AMBIGUITY: whether a denial remedy may point a plain HTTP request at the
Scrapling stealth tier — (a) yes, it is the only replacement the denial
concerns; (b) no, route first to `WebFetch`, `fetch_readable` and scripts as
`search-and-cite` does; code: neither.

## Review of the review

A third cell (sonnet), given the artifact and this table, fired the hook for
`browser_save_state` and `make_request` and checked each claim against
upstream Scrapling 0.5.1 and the launcher at `0041094`. Every finding is P2 by
the rule.

- **R1, R2, R5 supported.** `close_session` drops the browser and its cookies
  (upstream `server.py:405-420`); upstream `make_request` takes `method`,
  `data` and `json` (`:719-760`), which no browser tool replaces.
- **R3 partly supported**: `browser_open`'s schema already shows the required
  `session_id`; the Appium half carries little weight in a Scrapling remedy.
- **R4 unsupported as written**: "several pages from one site" is advice on
  when a session fits, not a limit, and the 25-page bound belongs to the run.
- **R6 partly supported**: `open_request_session` only creates a
  `FetcherSession` (`:384-403`); opening with a noun is style.

It named two gaps:

| # | Sev | Finding |
|---|---|---|
| N1 | P2 | The test asserts only exit 2 and "Instead,": a remedy naming a tool the narrowed server does not list stays green |
| N2 | P2 | The three raw-HTTP `instead` strings are byte-identical, so an edit must land three times |

## Dispositions

No finding blocks, so the lane is accepted at `3c20027`, and the adopted P2s
trail it as one commit, since the lead rewrote that text anyway.

| # | Disposition |
|---|---|
| R1 | Adopted: the state remedies say a login ends with `close_session` and does not carry to a later session, and a page that needs a login the browser session lacks goes to the operator's question: their own login, another source, or stop |
| R2 | Adopted, settling the ambiguity as (b): a plain page goes to `WebFetch` or `fetch_readable`, an API or a request with a body to a script run with Bash, a write behind the operator's approval, and the stealth browser only for a page those cannot read |
| R3 | Adopted in part: each remedy says to choose a `session_id` and pass the same one to `browser_fetch` and `close_session`, and names `browser_fetch_once` as Scrapling's; the Appium half declined, per the review of the review |
| R4 | Adopted as wording: "from one site" dropped; the bound is not named, since it belongs to the run |
| R5 | Adopted: "the launcher's refusal of non-web and cloud-metadata addresses and the record of pages read" |
| R6 | Adopted: `open_request_session` opens a session whose requests skip both; each `instead` opens with an action |
| N1 | Breadcrumb: check each tool a remedy names against the registry or the launcher's kept tools |
| N2 | Accepted: JSON has no shared strings, and a loader change in `denied-tool.sh` costs more than three identical entries; the three were edited together |

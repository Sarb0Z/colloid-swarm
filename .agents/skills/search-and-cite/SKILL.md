---
name: search-and-cite
description: Use when a turn rests on an external fact — a library API, a version, a "current best practice", anything the agent would otherwise assert from memory. Draws the line between a quick inline lookup and delegating a researcher cell, and carries sources through to the answer. Everyday citation hygiene, not a full research report.
---

# Search and cite

This skill ends two failures: an external fact asserted from memory, unsearched
and uncited, and its quieter twin — one search, one dead page, and the claim made
anyway. Two moves end both: a **cheap inline lookup** for a single known fact,
or a **delegated researcher cell** for anything load-bearing; either way the
claim ends tied to a URL.

Nothing here can force the search: a claim from memory makes no tool call, so no
hook sees it. The scaffold makes searching cheap and disciplined and leaves an
evidence trail, and the `research-prime` hook flags a user's question that reads
as research; the decision remains the agent's. Never state as fact what you did
not verify.

## Inline, or delegate

**Inline fast-path:** run one `WebSearch`, read the top primary source with
`WebFetch`, cite the URL; no cell. When `WebFetch` returns navigation, a cookie
wall, or boilerplate instead of the text, re-read the same URL with
`research-mcp`'s `fetch_readable`, which also reads the PDFs `WebFetch` cannot.
Use the fast path for a **single, well-known, low-stakes fact**:
- "What's the current Node LTS?" · "Does `Array.prototype.at` exist in Node 18?"
- "What's the latest stable Postgres major?"

**Delegate a researcher cell** when the answer is **multi-claim, contested,
version-sensitive, or load-bearing** (a wrong answer changes the code that
ships):
- "Is library X compatible with Y across our version range, and what's the
  migration path?"
- "What's the current best-practice for Z, and where do practitioners say it
  breaks?"
- anything touching security or data integrity, where one source is not enough.

Where the line is unclear and being wrong costs something real, delegate: the
researcher demands two independent sources per load-bearing claim and keeps its
search context out of yours.

## Delegating a researcher

Dispatch it with the question; `.agents/personas/researcher.md` is its
engine-neutral contract — escalation ladder, corroboration rules, and
`CLAIMS / SOURCES / GAPS` return shape.
<!-- colloid-only -->

A cell like any other, it takes the **Mycelium** as its natural genome (trace
every source, three hops out, impossible to surprise). Generate the stamp only
on a host whose `SubagentStart` injects no context:

```sh
.agents/genome.sh mycelium --register none   # Kimi: prepend to the dispatch prompt
```
<!-- /colloid-only -->

### Claude Code — use the native researcher agent (Claude Sonnet 5)

Under Claude Code, delegate research to the dedicated `researcher` agent, so it
runs on **Claude Sonnet 5** instead of inheriting the parent model:

```
Task(
    subagent_type='researcher',
    prompt='[your research question]'
)
```

`.claude/agents/researcher.md` links to `.agents/personas/researcher.md` and pins
`sonnet` in its frontmatter; the contract becomes the agent's system prompt,
your prompt carries the question, and `sources-capture` logs its web calls.
<!-- colloid-only -->

Claude Code and Codex stamp the cell on `SubagentStart`; a second stamp gives it
two personalities. Kimi's event is observation-only, so prepend one there:
`prompt='[genome stamp] + [your research question]'`.
<!-- /colloid-only -->

### Other engines — generic dispatch

Dispatch `[.agents/personas/researcher.md] + [your research question]`. The cell
climbs the escalation ladder (WebSearch → WebFetch primary sources →
context7 for libs → research-mcp for articles, PDFs and open-access copies →
playwright for hard pages), cross-checks load-bearing claims, and returns
`CLAIMS / SOURCES / GAPS` — what it found, not what it wishes it found.
<!-- colloid-only -->

On Kimi, prepend the genome stamp here too — `[genome stamp] +
[.agents/personas/researcher.md] + [your research question]`; Claude and Codex
inject it.
<!-- /colloid-only -->

## Carry the sources through

The researcher's `SOURCES` become the answer's sources. When writing it:
- Every external fact you repeat must trace to a URL the researcher returned (or
  one fetched inline). A fact tied to no source is not stated as fact: downgrade
  it ("likely, but unverified") or drop it.
- End an answer that rests on external facts with a **Sources** list of the URLs
  it used (`WebSearch`'s own contract asks for this; honour it).
- **Relay a GAP as a conclusion, never a hedge.** Say *"research found no
  authoritative source for Z; best available is W, low confidence"* — a finding.
  Not *"I'm unable to verify Z without more info"* — that reads as a stalled
  investigation and trips the session's investigate-then-act guard. The
  researcher hands gaps back already in conclusion shape; keep them that way, and
  route around the guard's trip-wires: *"unable to determine"*, *"cannot
  determine whether"*, *"without more context"*, *"you'll need to check"*. State
  what the search found, not what you could not do.

## The evidence trail

The `sources-capture` hook logs every observable `WebSearch` / `WebFetch` /
Context7 / `browser_navigate` / `fetch_readable` / `resolve_open_access` call,
the researcher cell's included, to `.agents/.sources-ledger`
(`ts · agent · kind · value`). Codex hosted web search bypasses local tool
hooks; its MCP calls are captured. The ledger is the operator's audit trail and
a backstop for the URLs read (`fetch`/`browse` rows are real URLs; `search` rows
hold the query, not the result link). Transient and gitignored; safe to delete.

## File what a cell found

The ledger records that a lookup happened, not what it found, and is never
committed; nothing later reads it for answers.

**File what a delegated cell returned.** Delegation is the test, drawn at the
top of this skill, that the question was substantial, and the answer is a dated
observation of something outside the repository. Write it to
`.agents/knowledge/research/` with its index line, per the entry contract in
`.agents/knowledge/README.md`.

**An inline lookup files nothing.** One fact earns no entry, and a store
padded with one-line entries is a store nobody opens.

You file, never the cell: it answers one angle, and only you hold the question
that angle was cut from, so only you can write an entry that reads as an answer
rather than a fragment.

## On other engines

`researcher.md` and this skill are engine-neutral, working wherever the engine
has web tools. The hook adapters map each host's observable tool names into one
shared source trail and wire the prompt-submit reminder. Hosted calls outside a host's hook path remain
an explicit coverage gap; the rule against stating the unverified does not
depend on the ledger.

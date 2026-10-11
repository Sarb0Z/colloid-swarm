---
name: search-and-cite
description: Use when a turn rests on an external fact — a library API, a version, a "current best practice", anything the agent would otherwise assert from memory. Draws the line between a quick inline lookup and delegating a researcher cell, and carries sources through to the answer. Everyday citation hygiene, not a full research report.
---

# Search and cite

An external fact asserted from memory, unsearched and uncited — or searched
once, lost, and abandoned — is the failure this skill ends. Two moves end it: a
**cheap inline lookup** for a single known fact, or a **delegated researcher
cell** for anything load-bearing; either way the claim ends tied to a URL.

No hook can force the search: a claim from memory makes no tool call, so
nothing intercepts it. The scaffold makes searching cheap and disciplined and
leaves an evidence trail, and the `research-prime` hook flags a user's question
that reads as research; the decision to search remains the agent's. Never state
as fact what was not verified.

## Inline, or delegate

**Inline fast-path.** Run one `WebSearch`, read the top primary source with
`WebFetch`, and cite the URL, with no cell. When `WebFetch` returns navigation, a cookie
wall, or boilerplate in place of the text, re-read the same URL with
`research-mcp`'s `fetch_readable`, which also reads the PDFs `WebFetch` cannot.
Use the fast path for a single, well-known, low-stakes fact:
- "What's the current Node LTS?" · "Does `Array.prototype.at` exist in Node 18?"
- "What's the latest stable Postgres major?"

**Delegate a researcher cell** when the answer is multi-claim, contested,
version-sensitive, or load-bearing — a wrong answer changes the code that
ships:
- "Is library X compatible with Y across our version range, and what's the
  migration path?"
- "What's the current best-practice for Z, and where do practitioners say it
  breaks?"
- Any question touching security or data integrity, where one source is not
  enough.

Where the line is unclear and being wrong costs something real, delegate: the
researcher cross-checks, and its search context stays out of the lead's.

## Delegating a researcher

Dispatch it with the question. `.agents/personas/researcher.md` is the
engine-neutral contract: the escalation ladder, the corroboration rules, and the
`CLAIMS / SOURCES / GAPS` return shape.
<!-- colloid-only -->

It is a cell like any other, and the **Mycelium** is its natural genome: every
source traced three hops out, impossible to surprise. Generate the stamp
explicitly only on a host without a context-injecting `SubagentStart`:

```sh
.agents/genome.sh mycelium --register none   # Kimi: prepend to the dispatch prompt
```
<!-- /colloid-only -->

### Claude Code — use the native researcher agent (Claude Sonnet 5)

Under Claude Code, research goes to the dedicated `researcher` agent, so it
runs on **Claude Sonnet 5** rather than inheriting the parent model:

```
Task(
    subagent_type='researcher',
    prompt='[your research question]'
)
```

`.claude/agents/researcher.md` links directly to
`.agents/personas/researcher.md`, and its frontmatter pins `sonnet`. The agent
loads the researcher contract as its system prompt; the dispatch prompt carries
the question; `sources-capture` logs its web calls.
<!-- colloid-only -->

Claude Code and Codex stamp the cell on `SubagentStart`, and a second stamp
prepended by hand gives it two personalities. Kimi's event only observes, so
prepend one there: `prompt='[genome stamp] + [your research question]'`.
<!-- /colloid-only -->

### Other engines — generic dispatch

Dispatch `[.agents/personas/researcher.md] + [your research question]`. The
cell climbs the escalation ladder (WebSearch → WebFetch primary sources →
context7 for libs → research-mcp for articles, PDFs and open-access copies →
playwright for hard pages), cross-checks load-bearing claims, and returns
`CLAIMS / SOURCES / GAPS` — what it found, not what it wishes it had found.
<!-- colloid-only -->

On Kimi, prepend the genome stamp here too — `[genome stamp] +
[.agents/personas/researcher.md] + [your research question]`. Claude and Codex
inject it automatically.
<!-- /colloid-only -->

## Carry the sources through

The researcher's `SOURCES` become the answer's sources. When writing the answer:
- Every external fact the answer repeats must trace to a URL the researcher
  returned, or to one fetched inline. A fact that ties to no source is not
  stated as fact: downgrade it ("likely, but unverified") or drop it.
- End an answer that rests on external facts with a **Sources** list of the URLs
  it used; `WebSearch`'s own contract asks for this, so honour it.
- **Relay a GAP as a conclusion, never a hedge.** *"research found no
  authoritative source for Z; best available is W, low confidence"* is a
  finding. *"I'm unable to verify Z without more info"* reads as a stalled
  investigation and trips the session's investigate-then-act guard. The
  researcher hands gaps back already in conclusion shape; keep them that way,
  and route around the guard's trip-wires: *"unable to determine"*, *"cannot
  determine whether"*, *"without more context"*, *"you'll need to check"*. State
  what the search found, not what could not be done.

## The evidence trail

The `sources-capture` hook logs every observable `WebSearch` / `WebFetch` /
Context7 / `browser_navigate` / `fetch_readable` / `resolve_open_access` call to
`.agents/.sources-ledger` (`ts · agent · kind · value`). Codex hosted web search
bypasses local tool hooks; its MCP calls are captured. The ledger is the
operator's audit trail and a backstop for the URLs read (`fetch`/`browse` rows
are real URLs; `search` rows hold the query, not the result link). It is
transient and gitignored, and deleting it costs nothing.

## File what a cell found

The ledger records that a lookup happened. It carries no findings and is not
committed, so nothing later reads it for answers.

**File what a delegated cell returned.** Delegation is itself the test that the
question was substantial — the line drawn at the top of this skill — and the
answer is a dated observation of something outside the repository. Write it to
`.agents/knowledge/research/` and add its index line; the entry contract is in
`.agents/knowledge/README.md`.

**An inline lookup files nothing.** One fact earns no entry, and a store padded
with one-line entries is a store nobody opens.

The lead files, never the cell. The cell answers one angle and hands it back;
only the lead holds the question that angle was cut from, so only the lead can
write an entry that reads as an answer rather than a fragment.

## On other engines

`researcher.md` and this skill are engine-neutral: the researcher cell and the
inline-or-delegate discipline work wherever the engine has web tools. The hook
adapters map each host's observable tool names into one shared source trail and
wire the prompt-submit reminder. Hosted calls outside a host's hook path remain
an explicit coverage gap, and the rule against stating the unverified does not
depend on the ledger.

---
name: search-and-cite
description: Use when a turn rests on an external fact — a library API, a version, a "current best practice", anything the agent would otherwise assert from memory. Draws the line between a quick inline lookup and delegating a researcher cell, and carries sources through to the answer. Everyday citation hygiene, not a full research report.
---

# Search and cite

The failure this kills: asserting an external fact from memory, never searching,
never citing — or searching once, failing, and giving up. Two moves fix it: a
**cheap inline lookup** for a single known fact, or a **delegated researcher
cell** for anything load-bearing. Either way, the claim ends up tied to a URL.

Be honest about the ceiling: nothing here *forces* you to search — a from-memory
claim makes no tool call, so no hook can catch it. This scaffold makes searching
*easy and disciplined* and leaves an evidence trail; the decision to reach for
it is yours. The `research-prime` hook reminds you when the user's question
looks research-shaped, but the membrane is your own honesty: *don't state as
fact what you didn't verify.*

## Inline, or delegate? Draw the line

**Inline fast-path** — one `WebSearch`, read the top primary source with
`WebFetch`, cite the URL. No subagent. When `WebFetch` returns navigation, a
cookie wall or boilerplate instead of the text, re-read the same URL with
`research-mcp`'s `fetch_readable` — it also reads PDFs, which `WebFetch` cannot.
Use the fast path for a **single, well-known, low-stakes fact**:
- "What's the current Node LTS?" · "Does `Array.prototype.at` exist in Node 18?"
- "What's the latest stable Postgres major?"

**Delegate a researcher cell** — when the answer is **multi-claim, contested,
version-sensitive, or load-bearing** (a wrong answer changes the code you
ship):
- "Is library X compatible with Y across our version range, and what's the
  migration path?"
- "What's the current best-practice for Z, and where do practitioners say it
  breaks?"
- anything security- or data-integrity-sensitive, where one source isn't enough.

When in doubt and the cost of being wrong is real: delegate. The researcher
cross-checks and isolates the search context from yours.

## Delegating a researcher

Dispatch it with the question. `.agents/personas/researcher.md` is the
engine-neutral contract: the escalation ladder, the corroboration rules, and the
`CLAIMS / SOURCES / GAPS` return shape.
<!-- colloid-only -->

It's a cell like any other — stamp it with a genome first. The **Mycelium** is
its natural genome (trace every source, three hops out, impossible to surprise):

```sh
.agents/genome.sh mycelium --register none   # stamp; then prepend .agents/personas/researcher.md + the question
```
<!-- /colloid-only -->

### Claude Code — use the native researcher agent (Sonnet)

When running under Claude Code, delegate research via the dedicated
`researcher` subagent so it runs on **Sonnet** instead of inheriting the parent
model:

```
Task(
    subagent_type='researcher',
    prompt='[your research question]'
)
```

The `.claude/agents/researcher.md` definition is generated from `.agents/config.json`
by `.agents/sync-claude-agents.sh`; the `model:` frontmatter pins whatever model
you configured (`sonnet` by default). The agent loads the researcher contract as
its system prompt, and your prompt carries the question. `sources-capture` logs
its web calls.
<!-- colloid-only -->

Prepend the genome stamp to that prompt — `prompt='[genome stamp] + [your
research question]'`. The `genome-guard` hook still applies, and the stamp is in
the prompt, so it passes.
<!-- /colloid-only -->

### Other engines — generic dispatch

Dispatch `[.agents/personas/researcher.md] + [your research question]`.
It climbs the escalation ladder (WebSearch → WebFetch primary sources →
context7 for libs → research-mcp for articles, PDFs and open-access copies →
playwright for hard pages), cross-checks load-bearing claims, and returns
`CLAIMS / SOURCES / GAPS` — what it found, not what it wishes it found.
<!-- colloid-only -->

Prepend the genome stamp here too — `[genome stamp] +
[.agents/personas/researcher.md] + [your research question]`. The stamp means the
cell carries the membrane and the honesty clause.
<!-- /colloid-only -->

## Consume the evidence — carry the sources through

The researcher's `SOURCES` are now **your** sources. When you write the answer:
- Every external fact you repeat must trace to a URL the researcher returned (or
  one you fetched inline). If you can't tie it to a source, don't state it as
  fact — downgrade it ("likely, but unverified") or drop it.
- End an answer that rests on external facts with a **Sources** list of the URLs
  you actually used (`WebSearch`'s own contract asks for this; honour it).
- **Relay a GAP as a conclusion, never a hedge.** Say *"research found no
  authoritative source for Z; best available is W, low confidence"* — a finding.
  Not *"I'm unable to verify Z without more info"* — that reads as a stalled
  investigation and trips the session's investigate-then-act guard. The
  researcher hands you gaps already in conclusion shape; keep them that way, and
  route around the guard's trip-wires: *"unable to determine"*, *"cannot
  determine whether"*, *"without more context"*, *"you'll need to check"*. State
  what the search found, not what you couldn't do.

## The evidence trail

Every `WebSearch` / `WebFetch` / `browser_navigate` / `fetch_readable` /
`resolve_open_access` — yours and the
researcher's — is logged to `.agents/.sources-ledger` (`ts · agent · kind ·
value`) by the `sources-capture` hook. It's the operator's audit trail and a
backstop for the URLs you actually read (`fetch`/`browse` rows are real URLs;
`search` rows hold the query, not the result link). Transient and gitignored;
safe to delete.

## On other engines

`researcher.md` and this skill are engine-neutral — the researcher cell and the
inline/delegate discipline work anywhere the engine has web tools. The
mechanical pieces are Claude-wired: the `sources-capture` ledger needs the
engine's web-tool names, and the `research-prime` reminder needs a prompt-submit
hook. Under an engine without those (e.g. Kimi today), you get the researcher
and the discipline, but no automatic trail and no prime — the honesty is then
entirely yours.

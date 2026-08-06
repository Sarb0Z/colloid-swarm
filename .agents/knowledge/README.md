# `knowledge/` — dated observations from outside the repository

The knowledge store holds what an agent cannot re-derive by reading this
repository. Everything here is an **observation**: a thing that was true on a
date, recorded with its source.

## What belongs

Apply one test: **delete the entry — can an agent reconstruct it from the
repository?**

- It can reconstruct how the code works, what changed, what is deferred, and
  which decisions the tree already encodes. That is not knowledge. Do not
  store it.
- It cannot reconstruct a competitor's pricing page, an effect size from a
  paper, or what a customer said on a call. That is knowledge. Store it.

Two classes, one directory each.

| Directory | Holds | Written by |
|---|---|---|
| `research/` | Distilled findings: competitor teardowns, market structure, prior art, benchmark numbers | The `market-researcher` skill, or whoever dispatched a researcher cell — never the cell itself |
| `transcripts/` | Raw human material: customer calls, user interviews, design discussions | A person, by hand |

A research entry is graded and summarized. A transcript entry is verbatim and
unedited — never summarize one in place, because the summary destroys the only
copy of the source.

Each directory appears with its first entry. Git tracks no empty directory, so
an absent one means the store holds nothing of that class yet.

## Why dates are content here, not history

The repository rule against dates in documentation bans **narrating change**:
"previously", "renamed in June", changelog notes. It does not apply to an
observation's own timestamp.

An entry's date is load-bearing. It states the claim's scope: not "this
competitor charges $40" but "this competitor charged $40 on 2026-08-06". Strip
the date and the entry becomes an assertion about the present that nothing
verified. Keep every date in this directory.

## Entry format

Name each file `YYYY-MM-DD-<subject>.md`. Give it frontmatter, then the body.

```markdown
---
date: 2026-08-06
subject: <what this observes, in a few words>
kind: research | transcript
source: <url, or who was in the room>
---
```

A `research` entry uses the write-up structure in the `market-researcher`
skill, including its `[P]`/`[S]`/`[?]` grade on every claim. A `transcript`
entry adds a `participants:` field and carries the raw text below.

Never revise an entry to match later facts. Write a new entry and let the index
carry both dates. An observation that was wrong is still a record of what the
source said.

## The index

`index.md` holds one line per entry, date first. Create it with the first entry:

```
- 2026-08-06 · research · <subject> — <the one thing a reader needs to know>
```

**Read the index, not the directory.** One research entry runs to thousands of
words. Ten index lines cost about a hundred tokens and tell you whether opening
anything is worth it. The date leads so a reader sees an entry's age before
trusting it.

The index is authoritative for *what to load*, never for *what exists*. A person
who drops a transcript in will not update it. So list the two directories
whenever you consult the index, and add a line for anything missing.

## Boundaries

Four stores sit near each other. Keep them apart.

| Store | Holds |
|---|---|
| `knowledge/` | Dated observations of the world outside the repository |
| `memory/` | Facts about this project and its operator; the live copy is per-machine and harness-owned |
| `breadcrumbs.md` | Deferred work, as a queue |
| `debt-log.md` | Standing tradeoffs and deferred decisions |

A finding that produces work belongs in both: the observation here, the one-line
task in `breadcrumbs.md`.

## What must not go here

- Specifications of code this repository holds. The code is the specification,
  and a copy of it rots the moment the code moves.
- Session notes, status, or progress. Those are not observations of anything
  outside the repository.
- Anything a quick inline lookup produced. The `search-and-cite` skill covers
  the single-fact tier and writes nothing here. This store takes long-form
  output only.

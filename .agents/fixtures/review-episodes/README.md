# Review-episode corpus

Real hostile-review episodes, mined from session transcripts of this
fleet's own repositories. Each episode holds the artifact that was
reviewed, the intent it had to satisfy, and the findings the reviewer
returned with the lead's actual disposition of each one.

Use this corpus to A/B-test review-prompt designs against real work.
Synthetic fixtures with seeded defects give misleading results: they
make a prompt look good when it catches the defects you planted.

## Contents

41 findings across 6 episodes. Two backend, two frontend, one plan, one
repo-wide refactor.

| Fixture | Domain | Findings | Why it is useful |
| --- | --- | --- | --- |
| `cleanstack-web-disconnect-r1` | Next.js UI | 8 | A low-severity scope violation that needed a user decision |
| `cleanstack-web-disconnect-r2` | Next.js UI | 8 | Round 2 on the same file; round 1's own fix was wrong |
| `ms-domain-delete-fk-race` | Python, Postgres | 12 | Largest diff; mixed severities; one partial adoption |
| `ms-arf-forward-milter` | Python, Postfix | 3 | The escalation case: an undefined case reached implementation |
| `ms-unit0-quarantine-plan` | Plan text | 7 | Stale premise found by querying production; artifact was invalid |
| `muscle-app-rebrand-videos` | Multi-file refactor | 3 | Two declined findings; use them as noise |

## Layout

Each fixture directory holds three files:

- `artifact.*` — the exact state that was reviewed, before the review's
  fixes were applied. A `.diff`, a `.tsx`, or a `.md` plan.
- `intent.md` — the requirements, plan, or task statement, quoted from
  the session.
- `ground-truth.md` — the findings, each with a class, a disposition,
  and a quote as evidence.

`manifest.tsv` holds one row per finding for scoring scripts. Rebuild it
after you edit a ground-truth file:

```sh
python3 .agents/fixtures/review-episodes/build-manifest.py
```

## Schema

**Class** — what kind of finding it is:

- `REQUIREMENT` — the artifact does not do what the intent states.
  Scope violations belong here.
- `QUALITY` — a real defect that no requirement covers. Bugs, races,
  performance, accessibility, readability.
- `AMBIGUITY` — nobody specified the case. The code chose silently.

**Disposition** — what the lead did, observed in the transcript:
`ADOPTED`, `DECLINED`, `ESCALATED`, or `IGNORED`.

**Reachable** — `no` means the finding targets a file that the fixture
does not contain. Score those as out of scope, never as a miss.

## How to run an A/B

1. Give each arm the same fixture: the artifact, `intent.md`, and any
   working-tree context the original reviewer had.
2. Withhold `ground-truth.md` from every arm.
3. Score each arm against the manifest. Count recall of reachable
   findings, and count the rank of each `REQUIREMENT` finding.
4. Treat `DECLINED` findings as noise. An arm that reports them is not
   more thorough.

## Caveats

- The corpus records what happened, not what should have happened. Four
  findings are `IGNORED` because the lead never dispositioned them.
- Three `IGNORED` dispositions are inferred from silence. No decline
  reason exists in the transcript.
- `globals.css` and `use-escape-key.ts` are absent from the CleanStack
  fixtures. The repository is not available on disk, so the transcript
  is the only source. Five findings are therefore unreachable.
- The artifacts hold real source from private repositories. Keep this
  repository private, or strip the corpus before you change that.

## Baseline results

One A/B has run, against `cleanstack-web-disconnect-r1`. Treat it as an
anecdote: one fixture, one run per arm, no variance measurement.

The current mushed prompt found 5 of 7 reachable findings. It ranked the
requirement finding last. A two-phase prompt with a hard gate reported 1
of 7, but its phase 2 never ran. That number measures the gate, not
recall. The gate costs one extra review round. It does not lose
findings.

A corpus-wide count gives stronger evidence than that A/B. A phase-1
gate keyed on `REQUIREMENT` or `AMBIGUITY` findings fires in all 6
fixtures. None of those 8 findings invalidates its artifact. Two are
labelled MINOR, one LOW, and one was declined by the lead. The one
finding that does invalidate its artifact (`ms-unit0-quarantine-plan`
finding 1) is classed `QUALITY`, so a class-keyed gate misses it.

Conclusion: run both phases and report both. Key a hard stop to the
reviewer's statement that the artifact is invalid, never to a finding
class.

NOTE: class labels and the invalidating judgment come from the mining
pass. They are corpus-internal, not independent evidence.

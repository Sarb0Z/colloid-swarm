# Recurring-correction mining

An operator who types the same correction twice has found a defect the scaffold
let through. Prose that failed once fails again: the 2026-08-21 corpus
(`knowledge/research/2026-08-21-session-corrections-mined.md`) found eleven of
thirteen correction classes already covered by a written rule, with corrections
continuing through every one. This playbook turns the transcripts into the
cheapest evidence the scaffold generates about itself, and encodes each finding
at the lowest rung that holds.

Run it when the operator asks, or when the same complaint arrives in a third
session. It is its own unit of work, never folded into the change that
prompted it. Track record: 2026-07, 10 corrections mined, 5 adopted; 2026-08-21,
119 verified corrections in 13 classes, which produced `done-prime.sh`,
`ui-gate.sh` and six contract edits.

## Gather the inputs

- **Corpus.** Human-authored turns only, from `~/.claude/projects/*/*.jsonl`
  and, for sessions before 2026-09-01, `~/.codex/sessions/**/*.jsonl`. Drop
  subagent threads and hook or system injections; some still leak, so
  discard them by hand. Codex re-indexed Claude history on 2026-08-03, so
  de-duplicate on text before counting, and treat any host split across that
  date as unreliable.
- **Filter.** A keyword pass is a candidate generator, not a classifier.
  Expect precision near 30%; verify each candidate against the turn before
  it, which must show the agent behavior being corrected. Cap per-turn text
  and say so: long turns are undercounted.
- **Landing dates.** `git log -S'<phrase>'` dates every rule the corpus might
  have been answered by. A correction made before its rule landed is not
  evidence against the rule.

Reconstruct from the transcript's own user messages, never from a summary of
them. Quote verbatim, with project and date.

## Classify every correction

Give each verified correction exactly one disposition, with one line of
reasoning. Group first: a class is the unit, not the sentence, and a class
needs at least two corrections in separate sessions.

| Disposition | Meaning | Where it goes |
|---|---|---|
| **Encode as gate** | A defect a script can detect in a diff, prompt, or stop state; or prose already failed after landing | A lint rule, test, or hook with a firing test, wired into CI; no new prose |
| **Contract edit** | Judgement no script can read, and no rule exists yet | One sentence in the root `AGENTS.md`, or the system-prompt append when it must outrank a host default |
| **Already covered** | A gate or rule landed and no correction postdates it | Nothing; record the landing date as the receipt |
| **One-off** | A single session, or operator taste that did not repeat | Dropped, and counted |

Order of preference is gate, then contract edit. A class with a rule that
corrections outlived is a **gate**, not a stronger sentence: rewriting the
prose a second time is the failure this playbook exists to stop. A class whose
rule exists and whose corrections all predate it is **already covered**, however
loud the quotes.

Check each proposed gate against the harness before building it: a regex that
fires on 19% of prompts is noise, one that fires on 7% is a reminder. Measure
the rate on the corpus and record it beside the mining.

## One class, one change

Every adopted class ships as its own change with a firing test or, for a
contract edit, the one sentence. Do not batch unrelated classes. Interventions
that conflict across classes (over-asking against publishing without
permission) are resolved in one change that states the boundary, with the
operator's own words as the source.

## Record the mining

Write one `knowledge/research/` entry: method, corpus size, the class table
with counts, the rule or gate each class got, and every rejected class with
its reason. Counts come from a command, graded as the entry's own measurement.
Never revise an earlier mining; a later run is a new entry that cites it.

## Stop

Stop when every verified correction holds a disposition and every adopted one
is landed or filed as a breadcrumb. Report the corpus size, verified count,
the tally per disposition, and the classes escalated to the operator because
two rules pull opposite ways. A mining that adopts nothing is a valid result
only if its one-off and already-covered counts are stated.

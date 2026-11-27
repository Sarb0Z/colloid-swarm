# Review: status band plan

Round 1, plan review, by an Opus `reviewer` cell with the reviewer contract.
Artifact: `docs/notes/2026-11-28-status-band-plan.md` (an ignored local plan),
sha256 `cf891861cd5e0c10…` before and after the review. Verdict:
`CONFORMANCE: no`, 3 `P1` and 6 `P2`, no `P0`. The brief's contract block first
held a placeholder; a follow-up message named the contract's location before
the cell began, and the report follows that contract.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | The relay file and marker in `.agents/.readout/` collide with `readout.py`, which reads every `*.json` there as a readout (each would show `unreadable` and never be pruned), `prune` would delete the marker after 7 days, and the folder would then exist everywhere, so the reader starts in every repository | adopted: both live in a per-user runtime folder keyed by session id, `${TMPDIR:-/tmp}/colloid-status-$USER/`; acceptance 3 pins that no readout folder means no reader start |
| 2 | P1 | `/clear` changes the session id with no `session.start`, so the marker goes stale and the person's own line returns | adopted: the band checks `$.session.id()` on every draw and writes a missing marker; `session.end` removes only the ending id's; acceptance 8 covers `/clear` |
| 3 | P1 | The acceptance block cannot show "everything from the strip": one fixture covered two segments, and six pinned cases were missing | adopted: golden captures of the current strip, one fixture per segment and value class, committed before any change; every pinned case is ported into acceptance 3 and 4 |
| 4 | P2 | The relay and the band resolve different repositories | adopted through finding 1: neither resolves one to find the other |
| 5 | P2 | Timers start git and `python3` while idle, against the ruling's stated cost | adopted: git and the reader run only on a relay change or a tool call; the idle timer is an in-process stat; cost stated; acceptance 9 samples `ps` while idle |
| 6 | P2 | A failed `removed-callers.py` would read as zero callers, and the count's unit is undefined | adopted: `--json` output with a non-zero status on failure, `callers ?` on failure, the unit is call and import sites |
| 7 | P2 | The relay builds a path from an unvalidated `session_id` | adopted: ids outside `[A-Za-z0-9_-]` delegate and write nothing; acceptance 4 |
| 8 | P2 | F8 changed two variables at once | adopted: F8 restated as observed — interactive sessions require trust before any loading, `-p` draws no band — and dropped from the relay's rationale |
| 9 | P2 | Where the band does not load and the person has no user line, nothing shows | accepted and stated in the plan: the strip switched off behaved the same |

AMBIGUITY ("everything from the strip": segments only, or also its
behaviour): settled by the lead as both, from the operator's "keep
everything we designed".

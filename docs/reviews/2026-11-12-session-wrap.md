# Session wrap of 2026-11-12: review

The operator asked for a full session wrap over this session's files from
`53ce23e` to `f0a7d12`: the readout reader and its strip and session-start
wiring (unit 0), the Research row (unit 1), the build plan's edits after the
operator's OK, and the fresh-session wording record. Unit 0's and unit 1's
boundary reviews had covered most of it, so the wrap's reviewer (opus) was
told their findings and asked for what both missed.

| # | Sev | Finding | Evidence | Disposition |
|---|---|---|---|---|
| 1 | P1 | Plan row F28 was marked `observed` while its cited lines show only the transcript's path, and unit 5's fallback was removed on that claim | inspection | Adopted. F28 now holds what four transcripts showed (the first record carries the brief header); F29, that the file exists when the inbox hook first fires, is `inferred`; 5.1's fallback is restored and its first step probes F29 |
| 2 | P2 | 7.2 says the transplant runs the first probe, and 7.3 had no probe; nothing probes the carrier | inspection | Adopted. 7.3 runs `check` and the first `probe`; the carrier probes on request |
| 3 | P2 | Changes after the operator's OK read as approved text | inspection | Adopted. A "Changed after the operator's OK" section names 7.2, 1.3, 4.2's fallback and F28/F29 |
| 4 | P2 | No test shows a session's own readout in the strip or the note, only that others' are hidden | inspection | Adopted. Run `harness-u0-wrap` |
| 5 | P2 | A cut note's pointer does not run from the repository root and hides session readouts; `write`'s usage omits `--stale-after` | inspection | Adopted. Run `harness-u0-wrap` |
| 6 | P2 | The wording record's new rows contradict its scope note, mislabel landed drafts, omit control counts and one result, and paraphrase a quote; the index line is silent on them | inspection | Adopted. Scope note, labels, counts, the Plan-row result, both quotes and the index line corrected |
| 7 | P2 | Unit 0's live check in a real terminal is recorded nowhere | inspection | Adopted. The lead runs it in an interactive session in a detached terminal and records the result here |
| 8 | P2 | Session start starts two `python3` processes where no readout folder exists | reproduced | Adopted. Run `harness-u0-wrap` |
| 9 | P2 | Many readouts draw a third row wider than the terminal | reproduced (314 columns) | Deferred to unit 4, which adds the next readouts; the live check in finding 7 shows how the host draws it |
| 10 | P2 | Four headers describe the old behaviour | inspection | Adopted. Run `harness-u0-wrap` |
| 11 | P2 | Two concurrent prunes can race on a deleted file | theoretical | Accepted: nothing is lost and the next prune finishes |

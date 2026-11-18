# Review: phone replies bound by the quoted message

Covers: 94499792..de2d0e8

Scope: commits `1cff78f` and `651e812` under `.agents/iterm/phone` and
`.agents/test-phone-hooks.sh`, which let a Signal reply to a phone-link message
answer its permission event with `yes`, `no` or `no <reason>` and no id. The
contract is the paragraph after the grammar table in "Phone messages" of
`docs/notes/2026-11-17-phone-link-spec.md`. Stakes: critical, because the
binding decides which permission prompt a phone message approves.

One reviewer cell (Opus) read the scope whole with the rest of the link's
message handling. It refuted the other weighted paths: a quote from another
chat or person, a quote of the operator's own message, a reply to the `done`
of a settled event, a queued alert, a bare `yes` with no quote, and replies
that skip rules 1–3. QA (a `qa-verifier` cell) passed acceptance 1–8 and the
two-alerts case offline at `651e812`.

Round 1 found one `P1` and no `P0`.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | The map from a sent message's Signal timestamp to its event takes the later of two sends that share a timestamp, so a reply to alert A allows the call of alert B. The fake signal-cli makes timestamps unique, so the tests could not catch it. Whether signal-cli 0.14.10 can repeat a timestamp is not known. | Fixed in `de2d0e8`. Every delivered send binds through `_bind`; a timestamp that two messages share answers no event and writes one `errors.log` line. The new test (`test_two_sends_that_signal_cli_gives_one_timestamp_answer_neither_event`) failed before the fix, and failed again with the clash check removed. The fake's uniqueness test no longer reads as a property of signal-cli. |

The reviewer's ambiguity on rule 4 (which link answers an id-less reply once
contabo-hop runs one) is in `.agents/breadcrumbs.md`. Not verified live: that
the phone's `quote.id` equals the `timestamp` in signal-cli's send result. If
they differ, every reply is refused, the safe direction.

The run's verify command passed at `de2d0e8`, run by the lead.

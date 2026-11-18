# Review: phone messages answered in the operator's own words

Covers: 97ae800..2f5c704

Scope: commits `8927ae7` and `2f5c704` under `.agents/iterm/phone` and
`.agents/test-phone-hooks.sh`: one adapter per alert kind (`adapters.py`), and
phone messages bound by quote, then a named id, then the newest alert, where an
approval allows and any other text denies with the operator's text. Contract:
`docs/notes/2026-11-17-phone-link-spec.md`, "Phone messages". Stakes: critical,
because a phone message decides allow or deny on a permission prompt.

One reviewer cell (Opus) read the scope whole with the rest of the message path
and ran a probe for each finding; every `P1` is confirmed by its probe. The
approval check held against `yes but…`, `not ok`, `y no`, `👍👎`, combining
marks and a Cyrillic `уes`.

Round 1 found three `P1` and seven `P2` items and no `P0`.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | P1 | A plain approval typed before the newest alert existed, and delivered late, allows that alert's call. | Adopted. A plain message older than the newest message about an event is refused; the spec's rule 3 says so. |
| 2 | P1 | A send whose outcome is unknown (a timeout) leaves "newest" on the older alert, so a plain answer meant for the new one answers the old one. | Adopted. "Newest" counts from the send attempt. |
| 3 | P1 | `[m-abcde] no`, the id as the link writes it, names no event, and the text denies the newest call instead. | Adopted. An id inside brackets or punctuation in the first two words is named; spec rule 2 says so. |
| 4 | P2 | A plain answer after a deadline line about A answers B. | Adopted. "Newest" is the newest message about any event, deadline lines and replies included. |
| 5 | P2 | The 5 s guard compares the phone's timestamp with the Mac's clock at the send callback. | Adopted as the reviewer's option (b): measured from the message's Signal timestamp, with finding 1's check. |
| 6 | P2 | `Help.` and `Status.` deny the newest call. | Adopted: trailing punctuation does not count against "alone". |
| 7 | P2 | A word like `t-shirt` in the first two words is taken as another machine's event id, and the message is dropped with no reply. | Adopted: an id's letter must be a machine letter. |
| 8 | P2 | A message of only punctuation or invisible characters after the id denies with that text. | Adopted: it denies with `Denied from the operator's phone.` |
| 9 | P2 | Removing an id also removes the line breaks after it. | Adopted: only spaces and tabs go. |
| 10 | P2 | "Newest" follows the order of signal-cli's answers, not the timestamps. | Adopted with finding 1: the highest Signal timestamp. |

The reviewer's ambiguities are settled in the spec: `ok 👍` and `yes yes` allow
(every word an approval), and a `?` anywhere makes the message a question that
denies with its text.

# Scrapling unit 2: code review round 1

Unit 2 of `docs/handoff/2026-11-11-scrapling-review-fixes.md`: the teardown
gate (`.agents/hooks/policy/teardown-gate.sh`, which records what a session
opens and blocks Stop until each is closed) clears only the Scrapling browser
session a close names, by `session_id` and server; `unnamed` entries clear only
when none matches and all of that server's entries are unnamed; device entries
carry their server tag and only that server's close clears them; awk reads its
values through `ENVIRON`. Commit `1a2591e` on `a608850`, lane `u2` of run
`scrapling-u2`. Three reviewers, one axis each: the gate's state and its
bypasses (opus), its consumers and hosts (sonnet), the tests (sonnet).

## Findings

| # | Sev | Finding | Evidence |
|---|---|---|---|
| D1 | P1 | Device entries clear by server, not by session: two devices created on one Appium server, then one `delete`, and the pending file is gone and Stop passes with a device still held | reproduced |
| T1 | P1 | No row holds devices from two Appium servers: an untagged `-device` from the `delete` branch or from `APPIUM_CLOSE` leaves the suite green | reproduced (two mutations) |
| T2 | P1 | No row has one ID a prefix of another: a named close that deletes by prefix (closing `s1` clears `s10`) leaves the suite green | reproduced |
| T3 | P1 | No row sends another server's ID-less close to an all-unnamed server: `mine()` losing its server check leaves the suite green | reproduced |
| D2 | P2 | Entries the previous gate wrote never clear: an untagged device, an ID-less `stealth browser [x]`, a 64-character ID cut to 59 plus "…"; each re-arm blocks Stop on them again | reproduced |
| D3 | P2 | Without the launcher, upstream generates an ID for an ID-less open: two such opens and a close naming the generated ID sweep both; a named open plus an ID-less one leaves the closed one blocking | reproduced |
| D4 | P2 | The fallback `unnamed` is a valid ID: a session named `unnamed` is swept by a close naming an unknown ID, and closing it drops the malformed-ID entries too | reproduced |
| D5 | P2 | `awk … > "$tmp" \|\| true` then `mv` empties the pending file when awk fails: every entry stops blocking Stop | reproduced with a failing awk first on `PATH` |
| D6 | P2 | A `close_session` on a server holding both a stealth entry and a device clears both | reproduced; no known server exposes both |
| D7 | P2 | The gate's header ("CLEARING IS BY CLASS") and the `teardown-tiered-by-restart-cost` decision's reopen condition misdescribe the code, and the showcase embeds the header; `close_session` in `APPIUM_CLOSE` can never match | inspection |
| D8 | P2 | `teardown-gate.sh` grew 701 → 737 lines and its test 558 → 611, both over the 300-line mark | measured |
| K1 | P2 | The awk blocks ran only under macOS awk; CI's Ubuntu runner uses mawk | theoretical |
| K2 | P2 | No Codex or Kimi adapter row sends an Appium close, though the server segment now decides what clears | inspection |
| T4 | P2 | A close with no ID read as naming `unnamed` leaves the suite green | reproduced |
| T5 | P2 | Widening `SESSION_ID` (no length cap, `{1,8}`, adding space, `[`, `]`, `.` or backslash) leaves the suite green | reproduced |
| T6 | P2 | No device label carries a tag mid-label: a substring match in place of the suffix match leaves the suite green | reproduced |
| T7 | P2 | The `?close` arm's empty-file cleanup is dead: the end-of-loop check covers it | reproduced |
| T8 | P2 | `appium_label` does not validate `deviceName`, `udid` or `capabilities`, so a tab or newline could forge a pending-file line | inspection, outside the axis; the gate reviewer found tabs and newlines collapse to spaces |

AMBIGUITY: Unit 2's `?close` "never a device entry" beside its Appium rule —
(a) a `close_session` never clears a device; (b) it clears its own server's
devices, since Appium forks name their close `close_session`; code: b.

AMBIGUITY: a real `session_id` of `unnamed` — (a) collides with the fallback by
design; (b) is told apart from it; code: a.

K1 was run by the lead: the whole suite passes at `1a2591e` under mawk 1.3.4
and gawk, in a `python:3.12-slim` container.

Held, with evidence: no reader outside the gate parses the pending file's
entries; every host's normalizer passes `tool_input` whole, and the adapter row
goes red when `session_id` fails to reach the gate; the regenerated showcase is
byte-identical to what the generators produce at this commit; server names that
are prefixes of each other do not match; the `case` arms order correctly under
bash 3.2 and 5.3; the launcher's pydantic pattern and the gate's `fullmatch`
admit the same IDs.

## Review of the review

A fourth cell (opus), given the artifact and this table, drove the committed
gate with crafted payloads and ran each mutation against the whole suite, with
a control mutant that goes red to show the harness detects a failure.

- **D1 and T1 stand at P1.** Two devices on `appium-mcp`, one `delete` with or
  without a `sessionId`, and Stop passes. The three T1 mutants each restore
  clearing by class with the suite green, a G1-class regression in a guard.
- **T2 is P2**: the suite already pins exact-ID clearing with its `one`/`two`
  rows; the prefix case is an edge of a tested claim, as the plan's T3 was.
- **T3 is P2, and its row would not catch the mutant**: the mutant cannot
  over-clear, since both `want` and `anon` carry the tag; it fails to clear
  another server's all-unnamed entries, one false block. The row that catches
  it: two servers, both unnamed, close one, its own entry gone.
- **D2 is worse than stated**: an old `stealth browser [scrapling]` entry also
  stops every later `unnamed [scrapling]` from being swept, and the pending
  file's seven-day expiry resets on every write.
- **T7's reason is wrong**: no end-of-loop check exists; the `-device
  <server>` verdict every `close_session` emits next runs the same cleanup.
- **T8 is unsupported**: `label()` joins on whitespace, turning tabs, newlines
  and line separators into spaces, and the label is always followed by
  ` [server]`.
- D3 to D8, K2, T4, T5 and T6 are supported at P2.

It named one gap:

| # | Sev | Finding |
|---|---|---|
| H1 | P2 | Stop's advice for a device names `appium_session_management` with `action=delete` whatever server opened it; on a fork server (`start_session`/`end_session`) that call goes to another server and clears nothing |

## Dispositions

D1 and T1 block, so the lane is reopened; the adopted P2s are fixed in the
same correction.

| # | Disposition |
|---|---|
| D1 | Adopted, settling the device ambiguity between (a) and (b): each device close drops one device entry of its own server, so N opens and M closes leave N−M entries and Stop blocks while any is held |
| D3 | Adopted with D1: a close that matches no named entry, on a server whose entries are all unnamed, drops one of them, not all |
| T1 | Adopted: a row with devices on two Appium servers, closed by `delete` and by `end_session`, each leaving the other server's device |
| T2 | Adopted at P2: `s1` and `s10` on one server, close `s1`, `s10` stays |
| T3 | Adopted at P2 with the review of the review's row: two servers both unnamed, close one, its own entry gone and the other's kept |
| D2 | Accepted, with the plan's "Not migrated" line corrected: entries written before this change never clear, block once per re-arm, and leave with the pending file when it is deleted; carrying a reader for the old format forever costs more than the sessions that span the upgrade |
| D4 | Adopted: the fallback becomes `(unnamed)`, which the ID pattern cannot produce; the ambiguity on a literal `unnamed` ID is settled as (b) |
| D5 | Adopted: when awk fails the pending file is kept and the gate says so on stderr |
| D6 | Accepted, with a comment at `CLOSE_SESSION` saying why its close also clears that server's devices |
| D7 | Adopted: the header says which classes clear whole and which by ID or by count, `close_session` leaves `APPIUM_CLOSE`, and the `teardown-tiered-by-restart-cost` decision says the same |
| D8 | Deferred: the handoff's row M records both files over the mark before this work |
| K1 | Closed: the suite passes under mawk and gawk |
| K2 | Breadcrumb: a Codex and a Kimi adapter row for an Appium close |
| T4 | Adopted: an unnamed and a named entry, a close with no ID, both stay |
| T5 | Adopted: a 64-character ID recorded whole; a 65-character ID, and IDs with a space, `]` or a backslash, recorded as `(unnamed)` |
| T6 | Adopted: a device label carrying another server's tag mid-label survives that server's close |
| T7 | Adopted: the redundant cleanup leaves the `?close` arm |
| T8 | Declined: `label()` collapses every whitespace character, per the review of the review |
| H1 | Adopted: the device advice tells the agent to call its own server's delete or `end_session` |

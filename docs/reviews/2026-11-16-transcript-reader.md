# Transcript reader: code review of workloop run `transcript-reader`

The operator ruled on 2026-11-16 to fix, as its own unit, the transcript
readers that read Claude Code's `api-request-blob` rows as conversation rows.
QA of the iTerm2 sidebar lane found the defect (`2026-11-15-iterm-console.md`,
lane `attention`, finding 13). The lead widened the lane from `turn-text.py`
to `last-message.py`, the one other reader with the same defect.

## Lane `fix` (critical)

Covers: 7c5e8863aa4e..f988a41ffd32

The writer reproduced the defect first: on a real transcript cut, the reader
before the fix gave turn id `start` and 427 characters of turn text, so
`provenance-gate.sh` did not deny and `stop-investigate.sh` did not block; with
the blob rows removed, the same transcript gave the prompt's uuid, 12,841
characters, a deny and a block. With the fix both copies read alike. The lead
reran the turn-id half of it. `last-message.py` returned a blob's or a
sidechain row's text in place of the real last reply on two synthetic
fixtures; no real transcript ends that way.

QA (sonnet) passed acceptance 1-6. On four real-transcript cuts, the old reader
keyed the turn `start` and read different text from the blob-free copy; the new
one matched. Over five fixtures, each plain, with a claim before the blobs, and
with a claim only inside an assistant-role blob, the old gates missed the
first claim and fired on the second, and the new ones matched the blob-free
copy in every case. Three Codex transcripts read the same before and after.

One reviewer (opus) read both commits and every caller. Over 150 recent
transcripts, the old reader keyed 129 turns `start` and the new one 1, which
holds no message rows; turn text changed on 32. Only `user`, `assistant` and
`api-request-blob` rows carry a message in 400 recent transcripts. Over 1,895
Codex transcripts, old and new readers gave identical output. No `P0` or `P1`
was found, so the disprove pass had nothing to run.

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | P2 | `last-message.py`'s docstring says it covers Codex's null `last_assistant_message`; it never read a Codex transcript (1,895 of 1,895 give "" before and after), so on those turns `stop-investigate.sh` judges nothing | The docstring is corrected in the trailing commit, since the lane edited it. A Codex reader is filed in `breadcrumbs.md` |
| 2 | P2 | Four readers each encode which rows are the conversation (`turn-text.py`, `last-message.py`, `cell_markers.py:172`, `agent_records.py:268`), and `lines_reversed` is copied twice: the third copy of one rule | Filed in `breadcrumbs.md`: two of the files are outside the lane |
| 3 | — | The writer: `last-message.py` returns "" when the last assistant row has no text block, older than this change | Filed in `breadcrumbs.md` |
| 4 | — | Reviewer handoff: Acceptance 4 at hook level on a real transcript | Covered by the writer's reproduction above, a real transcript with a real claim, run through both hooks with and without blob rows |

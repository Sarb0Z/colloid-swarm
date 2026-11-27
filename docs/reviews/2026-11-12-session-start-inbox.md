# Session start lost the workloop run list: review round 1

A full suite run on merged `main` after unit 4 found `test-session-start.sh`
failing with "session start did not surface the run in flight". Bisecting
from `bcb1251` (passing) to `dcdb073` named `1d01cdd` (review harness-u5): it
made `workloop-inbox.py` import `agent_silence.py`. The test's fixture copies
hook modules by name and lacked it, so the inbox died on
`ModuleNotFoundError`. `session-start.sh` ran the inbox with
`2>/dev/null || true`, so the failure showed only as a missing section.

The fix (`9473d01`) copies the module into the fixture and shows the inbox's
stderr when the inbox fails. The inbox prints its digest on stderr too, so
stderr is not passed on when it succeeds. A row runs a broken inbox. One
reviewer (sonnet) read it: no `P0` or `P1`.

| # | Sev | Finding | Evidence | Disposition |
|---|---|---|---|---|
| 1 | P2 | A start hook's stderr at exit 0 may reach no one, so the failure line can stay unseen | theoretical | Fixed (`5df36dd`): the failure also reaches the lead's context as a "Workloop runs unknown" section |
| 2 | P2 | A failed `mktemp` aborts the hook under `set -e`; the message ends in ": " when stderr is empty | inspection | Fixed (`5df36dd`): `mktemp` falls back to `/dev/null`, and the reason is printed only when present. A kill at the timeout can leave the temp file; accepted |
| 3 | P2 | Nothing asserts that a working inbox leaves stderr empty | inspection | Fixed (`5df36dd`): a row asserts it, and the broken-inbox row also asserts the context line |
| 4 | P2 | `parallel-writers-gate.sh:141` and `workloop-inbox.sh:65` discard `config.py`'s parse notice | inspection | Breadcrumb (`77a4b6d`) |
| 5 | P2 | `session-wrap.sh:575` reads a failing transcript counter as no events | inspection | Breadcrumb (`77a4b6d`) |
| 6 | P2 | `stop-investigate.sh:92` reads a malformed `policy.json` as no systems | inspection | Breadcrumb (`77a4b6d`) |

Each new row was shown failing: the broken-inbox row with stderr discarded
again, and the context assertion with the section's line removed.

Covers: f1cba3828ded..9e96863dcc58
Covers: 600667e54e64..74da178517b6

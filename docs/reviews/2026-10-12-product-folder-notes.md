# Review: product-folder notes (code round, 2026-10-12)

Plan: `docs/handoff/2026-10-05-product-folder-notes.md`, approved by the operator on 2026-10-12 with two amendments: every hidden path component below the product folder is outside the grant, matching the work-log ruling of 2026-10-11; and, after finding E1, the risky parts below are outside it too. Artifact: the diff from the hook-script-lookup tree to the working tree, sha256 `9ee22c7f…eada5`. Three axis reviewers and one review of the review, which labelled every finding supported and corrected T3's fix.

## QA

Live, headless Claude Code 2.1.294, fixture product folder under `$HOME` with the switch on. Passed: a `NOTES-ONLY` cell dispatched beside a live writer wrote `worklog/x.md` with no prompt; its writes to the checkout, `.vercel/` and a sibling repository were refused; a `READ-ONLY` cell's product-folder write was refused while the grant allowed it on the same call; the lead's write to the product folder's `AGENTS.md` prompted; with the switch off the `NOTES-ONLY` dispatch was refused and the write prompted. Each cell's `meta.json` carried the dispatch's `toolUseId`, and marked cells left the live writers at their first file-tool call. An `Edit(path)` deny rule refused a write with the grant on; a `Write(path)` rule did not, which matches Claude Code's documentation (only `Edit(path)` and `Read(path)` rules are consulted). Not reproduced: plan and auto mode, because headless runs on this machine are forced to default mode; the grant's plan-mode silence is covered by tests only.

## Findings

| # | Severity | Finding | Disposition |
|---|---|---|---|
| E1 | P1 | The grant opened every non-hidden file outside checkouts, including tax-appeals-app's `tools/` production scripts, `backups/` and `node_modules/` | Operator ruling: refuse folders named `tools`, `backups`, `node_modules`, `__pycache__` at any depth and `.py`, `.sh`, `.js`, `.mjs` files; a deny-list, stated as such |
| T1 | P1 | Under contention the lock fell through and demotion rewrote the live-writer file through a shared temporary name, losing `READ-ONLY` denials and erasing live writers (reproduced) | Adopted: decide before bookkeeping; one `unregister` helper that acts only under a held lock, through `mktemp`; concurrency row |
| S1 | P1 | No showcase card for the new hook; CI's showcase steps failed | Adopted: card added, pages re-embedded |
| E2 | P2 | A marked cell can dispatch a writer or `NOTES-ONLY` child | Accepted: no worse than the shell writes a marked cell already has; documented as a known limit |
| E3 | P2 | A checkout without a `.git` directory was opened by the grant | Adopted: `root()` requires one |
| E4 | P2 | A marked dispatch without an id recorded nothing and ran unmarked | Adopted: refused |
| E5 | P2 | An agent can switch the grant on by editing `.agents/config.json` | Debt `colloid-product-folder-switch-agent-writable` |
| T2 | P2 | A failed bookkeeping write exited 1 before recording; ids were sanitized on one side of the join only | Adopted |
| T3 | P2 | A same-turn marked cell could take a writer's pending slot and leave it consumed | Adopted with the corrected fix: each registration records the slot it consumed, and only that slot is restored |
| S2 | P2 | The debt pointer spanned two lines, so exports did not seed the entry | Adopted |
| S3 | P2 | With the switch on but the folder refused, the dispatch denial said the switch was off | Adopted: the denial quotes `root()`'s reason |
| S4 | P2 | Every cell write paid for a marker lookup under the lock | Adopted: exit before the lock when no marker ledger exists |
| S5 | P2 | Target-path extraction existed three times; the gate neared 300 lines | Adopted: one extractor in `hooks/lib/write_targets.py`; payload parsing moved to `hooks/lib/writers-payload.py` |
| S6 | P2 | Folder rules exist in both `product_folder.py` and `worklog.py` | Accepted: they answer different questions; each points at the other |
| S7 | P2 | `test-parallel-writers.sh` exceeds 300 lines | Declined: one policy and one shared fixture harness |
| S8 | P2 | The README's gate paragraph omitted the marker ledger and cell-write enforcement | Adopted |

Found during the fixes and filed: a marked cell that consumes a writer's pending slot and stops before writing loses the slot until that writer starts (breadcrumb).

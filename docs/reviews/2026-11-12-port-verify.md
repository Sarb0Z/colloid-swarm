# The public port's verify step and its terminated build: review round 1

Two full suite runs on clean clones failed `test-port-public.sh` on its SIGTERM
row ("the scratch copy survived SIGTERM"); five runs alone passed. The test's
own `rm -rf` failing with "Directory not empty" after the build had exited
pointed at a writer that outlived it: `subprocess.run` kills only its direct
child on an exception, so git's own children (and a check's) kept writing into
the scratch copy `build` removed. Reading `verify` on the way found a second
defect: since `63e9850` moved the check list from `.agents/AGENTS.md` into
`.agents/check-all.sh`, `verify` stopped with "no Verification list to run".

`88efc6c` runs `check-all.sh` in the filtered tree; the test fixture took the
real layout, which turned the clean rows red against the old code. `0417271`
runs each command in its own process group and kills the group on any exit;
its row (a check whose child outlives the build) failed against the old code
and against a mutant killing only the leader. One reviewer (sonnet) read both.

| # | Sev | Finding | Evidence | Disposition |
|---|---|---|---|---|
| 1 | P1 | A real build still stops at verify: in the filtered tree `test-wait-gate.py` is a SyntaxError and `test-browser-sync.py` fails | reproduced: `verify` on a filtered clone after 1129 s | Declined as a defect of these commits: both checks were on the old Verification list too (`git show 63e9850^:.agents/AGENTS.md`), and `test-browser-sync.py` passes in a clean clone of `88efc6c`. A real build on this machine stops earlier still, at `classify`, on names only the operator can classify. Breadcrumb (`367f59e`). `88efc6c`'s message overstates: builds here stopped at `classify` first |
| 2 | P2 | `killpg` on an emptied group raises `ProcessLookupError`, masking the real error, such as a decode failure | reproduced | Fixed (`367f59e`): `stop_group` returns when the group is empty; output that is not UTF-8 is replaced, not raised, with a row |
| 3 | P2 | A group that outlives the five-second wait is passed over silently | inspection | Fixed (`367f59e`): a warning on stderr names the group |
| 4 | P2 | `verify` prints nothing while `check-all.sh` runs for many minutes, and has no timeout | reproduced: 1129 s | Fixed in part (`367f59e`): each step is named as it starts. No timeout: a hung check is the operator's to stop, and the stop is clean |
| 5 | P3 | A command can no longer prompt on a terminal, so `--against` needs non-interactive credentials | inspection | Accepted: the GitHub credential helper answers without a prompt |
| 6 | P3 | The docstring says any exit kills the group whole; a descendant that calls `setsid` escapes | reproduced | Fixed (`367f59e`) |
| 7 | P3 | A second signal between `Popen` and `try`, or during the cleanup, can skip it | theoretical | Accepted: a window of microseconds |
| 8 | P3 | The new row's late-write assertion could not fire; the child-alive assertion carries it | reproduced | Fixed (`367f59e`): the assertion goes |

Covers: 76975e6..88efc6c
Covers: 1f5e14f..0417271
Covers: f51d3a2..367f59e

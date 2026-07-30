# Ground truth — real reviewer findings and real lead dispositions

Source: subagent `agent-abf6da641333251ab.jsonl` (final report), dispositions from
main transcript `9356fc23-...jsonl` line 657 (the lead's own disposition table).

Reviewer's own top-level verdict, verbatim:

> Bottom line: the core mechanism is **correct** — the FOR UPDATE/FOR KEY SHARE lock, the SET LOCAL ordering, the retry classification, and the cleanup_worker orphan-avoidance all hold up under scrutiny.

The reviewer additionally recorded 4 items as **verified correct** (item 1 SET LOCAL /
autobegin, item 2 `_sqlstate` resolution, item 3 cleanup_worker orphan-avoidance, item
5 idle-in-transaction). Those are not findings and are not numbered below.

Finding count: **12** (S1–S3 should-fix, N1–N5 nice-to-have, N6a–N6d minor sub-items).

---

## 1. S1 — deploy.sh log-dir owner

**Finding (≤25 w):** `deploy.sh:225` defaults log-dir owner to hardcoded `ubuntu`; the
systemd unit derives `User=` by `stat`-ing `$APP_DIR`. Divergence silently disables
file logging.

- **CLASS:** REQUIREMENT — the user asked "the deploy script should create logging directory if it doesn't exist"; a wrong owner reintroduces the exact unwritable-dir failure being fixed.
- **DISPOSITION:** ADOPTED
- **Evidence:** "**Fixed** — resolve via `stat -c '%U' \"$APP_DIR\"` like the installer"

## 2. S2 — fallback log dir never rotated

**Finding:** logrotate stanza covers only `/var/log/email-system/*.log`. Fallback
`/opt/email-system/logs` never rotates and `WatchedFileHandler` never rotates
in-process → unbounded disk growth.

- **CLASS:** QUALITY
- **DISPOSITION:** ADOPTED
- **Evidence:** "**Fixed** — rotate both dirs"

## 3. S3 — bare `await db.rollback()` can escape

**Finding:** `domain_deletion.py:215` rolls back unguarded inside `except`. A dead
connection makes `rollback()` itself raise, aborting the whole batch. Repo already has
`_rollback_session` (suppress+shield).

- **CLASS:** QUALITY
- **DISPOSITION:** ADOPTED
- **Evidence:** "**Fixed** — `_rollback_session` (suppress+shield)"

## 4. N1 — `_is_retryable` docstring is factually wrong

**Finding:** The `isinstance(exc, OperationalError)` fallback never fires; asyncpg
wraps deadlock/lock-timeout as generic `DBAPIError`. Retries hinge entirely on
`.orig.sqlstate`.

- **CLASS:** QUALITY
- **DISPOSITION:** ADOPTED
- **Evidence:** "**Fixed** — honest comment + `DBAPIError` backstop"

## 5. N2 — only the first physical line gets the `<N>` prefix

**Finding:** `ConsoleFormatter.format` prefixes once per record; journald splits on
newlines, so traceback continuation lines drop to PRIORITY=6=INFO and vanish from
"Errors Only".

- **CLASS:** REQUIREMENT — the stated goal was making the prod viewer's "Errors Only" work; tracebacks still disappear.
- **DISPOSITION:** ADOPTED
- **Evidence:** "**Fixed** — prefix every physical line"

## 6. N3 — concurrency primitive has zero real-DB test coverage

**Finding:** Retry tests monkeypatch both `_null_send_log_domain_refs` and
`_delete_domain_chunk_locked`, so FOR UPDATE, `ORDER BY id`, SET LOCAL and the DELETE
SQL are entirely untested.

- **CLASS:** QUALITY
- **DISPOSITION:** ADOPTED (partial — source-guard test added, full Postgres integration test deferred)
- **Evidence:** "**Partial** — added a source-guard test; full Postgres integration test **deferred** (needs a DB harness the repo lacks)"

## 7. N4 — reader cannot read compressed rotated logs

**Finding:** `logs.py:231-234` reads `.1`..`.5` uncompressed, but the new logrotate
uses `compress`+`delaycompress`, so rotated files are `.2.gz`+. Historical viewing
silently degrades.

- **CLASS:** QUALITY
- **DISPOSITION:** ADOPTED
- **Evidence:** "**Fixed** — gzip-aware, up to 30 rotations"

## 8. N5 — torn lines for >~8 KB records under concurrent writers

**Finding:** N uvicorn workers plus celery prefork share one `WatchedFileHandler` fd.
Concurrent writes of large records can interleave into torn lines; the reader skips
them.

- **CLASS:** QUALITY
- **DISPOSITION:** DECLINED (inherent to shared-file logging; reader tolerates it)
- **Evidence:** "**Accepted** — inherent to shared-file logging; reader tolerates it"

## 9. N6a — stale helper name in test assertion strings

**Finding:** `tests/test_domain_deletion_fk_cleanup.py:55,62` still name the deleted
`clear_domain_references` in assertion strings.

- **CLASS:** QUALITY
- **DISPOSITION:** ADOPTED
- **Evidence:** "**Fixed** all three"

## 10. N6b — `_active_log_dir` module cache is a global-state footgun

**Finding:** Only one test resets `_active_log_dir` (logging_config.py:154). A future
test calling `get_active_log_dir()` under a patched `ENVIRONMENT` without resetting it
becomes order-dependent-flaky.

- **CLASS:** QUALITY
- **DISPOSITION:** ADOPTED
- **Evidence:** "**Fixed** all three"

## 11. N6c — worker return omits `not_found`

**Finding:** `bulk_dns_worker.py:981` omits `not_found`; `total` can exceed
succeeded+failed when domains aren't account-owned. Reporting gap.

- **CLASS:** QUALITY
- **DISPOSITION:** ADOPTED
- **Evidence:** "**Fixed** all three"

## 12. N6d — `_null_send_log_domain_refs` has no iteration cap

**Finding:** The nulling loop is uncapped; a domain receiving sustained >5000-row
inserts could loop until statement_timeout. Pre-existing; reviewer noted, did not
attribute.

- **CLASS:** QUALITY
- **DISPOSITION:** IGNORED — absent from the lead's disposition table and from every
  fold-in edit; never mentioned again in the session.
- **Evidence:** (no disposition statement exists; the table lists only "N6a/b/c")

---

## Not counted as findings

The reviewer closed with an explicit non-finding, which the lead also dispositioned:

> **Pre-existing, not this diff (FYI):** cleanup_worker maps expired `provider_domains.domain` → `domains.name` ignoring `account_id`

Lead: "**Pre-existing**, not this diff — left as-is". Excluded from the count of 12
because the reviewer itself labelled it out of scope.

## Tally

- CLASS: REQUIREMENT 2 (S1, N2) · QUALITY 10 · AMBIGUITY 0
- DISPOSITION: ADOPTED 10 (one of them partial: N3) · DECLINED 1 (N5) · ESCALATED 0 · IGNORED 1 (N6d)

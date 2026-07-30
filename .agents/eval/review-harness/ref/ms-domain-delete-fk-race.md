# Reference findings
Each entry is one previously-reported finding on this artifact.

## R1
S1 — deploy.sh log-dir owner

`deploy.sh:225` defaults log-dir owner to hardcoded `ubuntu`; the systemd unit derives `User=` by `stat`-ing `$APP_DIR`. Divergence silently disables file logging.

## R2
S2 — fallback log dir never rotated

logrotate stanza covers only `/var/log/email-system/*.log`. Fallback `/opt/email-system/logs` never rotates and `WatchedFileHandler` never rotates in-process → unbounded disk growth.

## R3
S3 — bare `await db.rollback()` can escape

`domain_deletion.py:215` rolls back unguarded inside `except`. A dead connection makes `rollback()` itself raise, aborting the whole batch. Repo already has `_rollback_session` (suppress+shield).

## R4
N1 — `_is_retryable` docstring is factually wrong

The `isinstance(exc, OperationalError)` fallback never fires; asyncpg wraps deadlock/lock-timeout as generic `DBAPIError`. Retries hinge entirely on `.orig.sqlstate`.

## R5
N2 — only the first physical line gets the `<N>` prefix

`ConsoleFormatter.format` prefixes once per record; journald splits on newlines, so traceback continuation lines drop to PRIORITY=6=INFO and vanish from "Errors Only".

## R6
N3 — concurrency primitive has zero real-DB test coverage

Retry tests monkeypatch both `_null_send_log_domain_refs` and `_delete_domain_chunk_locked`, so FOR UPDATE, `ORDER BY id`, SET LOCAL and the DELETE SQL are entirely untested.

## R7
N4 — reader cannot read compressed rotated logs

`logs.py:231-234` reads `.1`..`.5` uncompressed, but the new logrotate uses `compress`+`delaycompress`, so rotated files are `.2.gz`+. Historical viewing silently degrades.

## R8
N5 — torn lines for >~8 KB records under concurrent writers

N uvicorn workers plus celery prefork share one `WatchedFileHandler` fd. Concurrent writes of large records can interleave into torn lines; the reader skips them.

## R9
N6a — stale helper name in test assertion strings

`tests/test_domain_deletion_fk_cleanup.py:55,62` still name the deleted `clear_domain_references` in assertion strings.

## R10
N6b — `_active_log_dir` module cache is a global-state footgun

Only one test resets `_active_log_dir` (logging_config.py:154). A future test calling `get_active_log_dir()` under a patched `ENVIRONMENT` without resetting it becomes order-dependent-flaky.

## R11
N6c — worker return omits `not_found`

`bulk_dns_worker.py:981` omits `not_found`; `total` can exceed succeeded+failed when domains aren't account-owned. Reporting gap.

## R12
N6d — `_null_send_log_domain_refs` has no iteration cap

The nulling loop is uncapped; a domain receiving sustained >5000-row inserts could loop until statement_timeout. Pre-existing; reviewer noted, did not attribute.

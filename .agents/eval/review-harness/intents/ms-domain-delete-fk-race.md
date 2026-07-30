# Intent — domain-delete FK race + log-viewer visibility

## 1. Task statement — the user, verbatim

Opening report:

> Deleting domains: task failed — (sqlalchemy.dialects.postgresql.asyncpg.IntegrityError) <class 'asyncpg.exceptions.ForeignKeyViolationError'>: update or delete on table "domains" violates foreign key constraint "send_logs_domain_id_fkey" on table "send_logs" DETAIL: Key (id)=(822b9e46-de5e-4257-b0f7-ae8e0262aff6) is still referenced from table "send_logs". [SQL: DELETE FROM domains WHERE domains.id IN ($1::UUID, $2::UUID, $3::UUID, $4::UUID, $5::UUID, $6::UUID, $7::UUID, $8::UUID, $9::UUID, $10::UUID)] [parameters: (UUID('bc7

Scoping message:

> the deploy script should create logging directory if it doesn't exist, also -> and journald stamps every stdout line as PRIORITY=6 = INFO.
> this seems weird?
>
>
> please investigate, debug the root and proximate cause of why deleting domains failed, fix error handling and propagation and then the actual problem itself as well.
> it wasn't a local run, it definitely failed on production, you must be looking in the wrong place, probably in celery logs or something
> if it was a race error, handle that as well? Our system should be engineered to be scalable.

## 2. Change description

> Background: this fixes (1) `DELETE FROM domains` tripping `send_logs_domain_id_fkey` — a race where FK-null commits then the DELETE runs in a separate txn and a concurrent send re-inserts a send_logs row; (2) prod log viewer "Errors Only" always empty because file logging was silently disabled (/var/log/email-system unwritable) and journald stamps all stdout PRIORITY=6=INFO.

> Files changed: backend/services/domain_deletion.py (the locked delete core `clear_and_delete_domains` + `_delete_domain_chunk_locked` + `delete_domains_in_batches`), backend/database.py (`set_local_lock_timeout`), backend/workers/bulk_dns_worker.py (delete branch), backend/workers/cleanup_worker.py (S0), backend/api/domains.py (single + bulk delete endpoints), backend/logging_config.py (writable-dir resolver, WatchedFileHandler, ConsoleFormatter `<N>` syslog-priority prefix under $JOURNAL_STREAM), backend/api/logs.py (reads log_dir_candidates, parses level from message), scripts/deploy.sh (mkdir log dir + logrotate), plus tests.

## 3. Binding requirements carried in from the earlier plan review

These are the stated requirements the implementation must satisfy:

> A prior plan review already required: route the daily `cleanup_expired_domains` through the same locked delete (S0), mandatory `db.rollback()` after aborted txn (S1), deterministic lock order (S2), WatchedFileHandler not RotatingFileHandler for multi-process safety (S3), a lock_timeout helper (S6), partial-failure accounting + no single-delete IndexError (S7). Verify each was actually done correctly, not just gestured at.

## 4. Project standing rules in force

From the repo's agent instructions, active during this session:

> Every change ships to production and must withstand hostile technical review — reviewer (Linus) rejects placeholder types, mock fallbacks, suppression comments, MVP shortcuts, and temporary hacks on sight.

> Comments and docs describe the code **as it is now**, never its history.

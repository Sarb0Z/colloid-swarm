"""Race-safe domain delete: retry, partial-failure, and rollback behaviour.

Exercises `clear_and_delete_domains` with the two chunk primitives monkeypatched
so no real database is needed — the point is the orchestration: a transient chunk
failure retries, a permanent one is recorded and does NOT abort the batch, and the
aborted transaction is always rolled back before the loop moves on.
"""
import asyncio
import uuid

import backend.services.domain_deletion as dd


class _FakeOrig:
    def __init__(self, sqlstate):
        self.sqlstate = sqlstate


class _FakePGError(Exception):
    """Mimics a SQLAlchemy DBAPIError carrying a PG SQLSTATE via `.orig`."""

    def __init__(self, sqlstate):
        super().__init__(f"pg error {sqlstate}")
        self.orig = _FakeOrig(sqlstate)


class _FakeSession:
    def __init__(self):
        self.rollbacks = 0

    async def rollback(self):
        self.rollbacks += 1


def _ids(n):
    return [uuid.uuid4() for _ in range(n)]


def _patch(monkeypatch, *, null=None, delete=None):
    async def _ok(*a, **k):
        return None

    monkeypatch.setattr(dd, "_null_send_log_domain_refs", null or _ok)
    monkeypatch.setattr(dd, "_delete_domain_chunk_locked", delete or _ok)


def test_sqlstate_and_reason_classification():
    assert dd._sqlstate(_FakePGError("23503")) == "23503"
    assert dd._sqlstate(ValueError("nope")) is None
    assert "active sends" in dd._failure_reason(_FakePGError("23503"))
    assert "contention" in dd._failure_reason(_FakePGError("40P01"))
    assert "ValueError" in dd._failure_reason(ValueError("nope"))


def test_all_chunks_succeed(monkeypatch):
    _patch(monkeypatch)
    ids = _ids(25)
    session = _FakeSession()
    res = asyncio.run(dd.clear_and_delete_domains(session, ids, batch_size=10))
    assert sorted(res.succeeded) == sorted(ids)
    assert res.failed == []
    assert session.rollbacks == 0


def test_permanent_failure_is_isolated_to_its_chunk(monkeypatch):
    ids = sorted(_ids(25))
    target = ids[12]  # lands in the middle chunk (10..19)

    async def selective_delete(db, chunk, **k):
        if target in chunk:
            raise ValueError("boom")  # non-retryable (no sqlstate)

    _patch(monkeypatch, delete=selective_delete)
    session = _FakeSession()
    res = asyncio.run(dd.clear_and_delete_domains(session, ids, batch_size=10))

    failed_ids = {cid for cid, _reason in res.failed}
    assert target in failed_ids
    # Only the one 10-domain chunk failed; the other 15 survived.
    assert len(res.succeeded) == 15
    assert len(res.failed) == 10
    assert session.rollbacks == 1  # exactly one aborted txn, rolled back once


def test_retryable_error_retries_then_succeeds(monkeypatch):
    ids = _ids(5)  # single chunk
    attempts = {"n": 0}

    async def flaky_delete(db, chunk, **k):
        attempts["n"] += 1
        if attempts["n"] == 1:
            raise _FakePGError("23503")  # foreign_key_violation — retryable

    _patch(monkeypatch, delete=flaky_delete)
    session = _FakeSession()
    res = asyncio.run(dd.clear_and_delete_domains(session, ids, batch_size=10))

    assert sorted(res.succeeded) == sorted(ids)
    assert res.failed == []
    assert attempts["n"] == 2  # failed once, retried, succeeded
    assert session.rollbacks == 1  # the aborted first attempt was rolled back


def test_retryable_error_gives_up_after_max_attempts(monkeypatch):
    ids = _ids(5)

    async def always_deadlock(db, chunk, **k):
        raise _FakePGError("40P01")  # deadlock — retryable but never clears

    _patch(monkeypatch, delete=always_deadlock)
    session = _FakeSession()
    res = asyncio.run(dd.clear_and_delete_domains(session, ids, batch_size=10))

    assert res.succeeded == []
    assert {cid for cid, _ in res.failed} == set(ids)
    assert session.rollbacks == dd.DOMAIN_DELETE_MAX_ATTEMPTS


def test_chunks_are_processed_in_sorted_order(monkeypatch):
    ids = _ids(30)
    seen = []

    async def record_delete(db, chunk, **k):
        seen.extend(chunk)

    _patch(monkeypatch, delete=record_delete)
    asyncio.run(dd.clear_and_delete_domains(_FakeSession(), ids, batch_size=10))
    # Global ascending order so concurrent deleters can't deadlock each other.
    assert seen == sorted(ids)


def test_progress_callback_reports_cumulative_done(monkeypatch):
    _patch(monkeypatch)
    ids = _ids(25)
    seen = []

    async def cb(done, total):
        seen.append((done, total))

    asyncio.run(dd.clear_and_delete_domains(_FakeSession(), ids, batch_size=10, progress_cb=cb))
    assert seen == [(10, 25), (20, 25), (25, 25)]

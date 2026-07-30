"""Logging must never silently go dark, and levels must survive the journald path.

Covers the two faults that hid a prod outage:
  1. file logging silently disabled when /var/log/email-system isn't writable
     -> here: resolve to an app-local writable dir instead of dropping to console.
  2. journald stamps every stdout line PRIORITY=6=INFO -> here: emit the syslog
     "<N>" prefix so journald stores the real level, and parse the level out of
     the console-formatted message as a fallback.
"""
import logging

import backend.logging_config as lc
from backend.api.logs import _level_from_message
from backend.logging_config import ConsoleFormatter


def _record(level, msg="hello"):
    return logging.LogRecord("t", level, "f.py", 1, msg, None, None)


# --- 1. writable-dir resolution -------------------------------------------

def test_dir_is_writable_true_for_tmp(tmp_path):
    assert lc._dir_is_writable(tmp_path) is True


def test_dir_is_writable_false_when_uncreatable(tmp_path):
    a_file = tmp_path / "a_file"
    a_file.write_text("x")
    # mkdir under a regular file raises NotADirectoryError (an OSError)
    assert lc._dir_is_writable(a_file / "sub") is False


def test_resolve_prefers_primary_when_writable(monkeypatch):
    monkeypatch.setenv("ENVIRONMENT", "production")
    monkeypatch.setattr(lc, "_dir_is_writable", lambda p: True)
    assert lc._resolve_log_dir() == lc._PRIMARY_PROD_LOG_DIR


def test_resolve_falls_back_when_primary_unwritable(monkeypatch):
    monkeypatch.setenv("ENVIRONMENT", "production")
    monkeypatch.setattr(
        lc, "_dir_is_writable", lambda p: p == lc._FALLBACK_PROD_LOG_DIR
    )
    assert lc._resolve_log_dir() == lc._FALLBACK_PROD_LOG_DIR


def test_dev_resolves_to_local_logs(monkeypatch):
    monkeypatch.setenv("ENVIRONMENT", "development")
    assert lc._resolve_log_dir() == lc._DEV_LOG_DIR


def test_reader_candidates_include_both_prod_dirs(monkeypatch):
    monkeypatch.setenv("ENVIRONMENT", "production")
    monkeypatch.setattr(lc, "_active_log_dir", None)
    monkeypatch.setattr(lc, "_dir_is_writable", lambda p: p == lc._FALLBACK_PROD_LOG_DIR)
    candidates = lc.log_dir_candidates()
    assert lc._PRIMARY_PROD_LOG_DIR in candidates
    assert lc._FALLBACK_PROD_LOG_DIR in candidates
    assert candidates[0] == lc._FALLBACK_PROD_LOG_DIR  # active dir first


# --- 2. level survives the journald path ----------------------------------

def test_console_formatter_prefixes_priority_under_journald():
    assert ConsoleFormatter(journald=True).format(_record(logging.ERROR)).startswith("<3>")
    assert ConsoleFormatter(journald=True).format(_record(logging.WARNING)).startswith("<4>")
    assert ConsoleFormatter(journald=True).format(_record(logging.INFO)).startswith("<6>")


def test_console_formatter_clean_without_journald():
    out = ConsoleFormatter(journald=False).format(_record(logging.ERROR))
    assert not out.startswith("<")
    assert "ERROR" in out  # level still present in the human-readable text


def test_level_parsed_from_console_message():
    assert _level_from_message("19:30:09 WARNING  [budget_sync] failed", "INFO") == "WARNING"
    assert _level_from_message("19:30:09 ERROR    [x] boom", "INFO") == "ERROR"
    # A traceback continuation line has no level token -> keep the fallback.
    assert _level_from_message('  File "x.py", line 3', "INFO") == "INFO"


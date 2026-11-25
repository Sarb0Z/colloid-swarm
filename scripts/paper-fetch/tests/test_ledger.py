from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from helpers import make_stamp

from paperfetch.ledger import (
    COLUMNS,
    FETCH,
    PUSH,
    Ledger,
    LedgerError,
    LedgerLocked,
    latest,
    read_rows,
    tool_hashes,
)
from paperfetch.scrub import scrub

SECRET = "zk_live_0123456789abcdef"


class LedgerTests(unittest.TestCase):
    def setUp(self) -> None:
        self._scratch = tempfile.TemporaryDirectory()
        self.path = Path(self._scratch.name) / "data" / "external" / "papers_ledger.csv"
        self.addCleanup(self._scratch.cleanup)

    def open(self, environ: dict[str, str] | None = None):
        return Ledger.locked(self.path, make_stamp(), environ or {})

    def test_first_open_writes_one_header_and_rows_read_back(self) -> None:
        with self.open() as ledger:
            ledger.append(key="a-1", doi="10.1/a", stage=FETCH, state="fetched", source="x", size=1234)
        with self.open() as ledger:
            ledger.append(key="a-1", doi="10.1/a", stage=FETCH, state="converted")
        text = self.path.read_text(encoding="utf-8")
        self.assertEqual(text.count(",".join(COLUMNS)), 1)
        rows = read_rows(self.path)
        self.assertEqual([row.state for row in rows], ["fetched", "converted"])
        self.assertEqual(rows[0].bytes, "1234")

    def test_latest_row_wins_per_key_and_stage(self) -> None:
        with self.open() as ledger:
            ledger.append(key="a-1", doi="d", stage=FETCH, state="converted")
            ledger.append(key="a-1", doi="d", stage=PUSH, state="failed")
            ledger.append(key="a-1", doi="d", stage=PUSH, state="pushed")
        states = latest(read_rows(self.path))
        self.assertEqual(states[("a-1", FETCH)].state, "converted")
        self.assertEqual(states[("a-1", PUSH)].state, "pushed")

    def test_header_line_anywhere_is_ignored(self) -> None:
        with self.open() as ledger:
            ledger.append(key="a-1", doi="d", stage=FETCH, state="fetched")
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write(",".join(COLUMNS) + "\n")
        self.assertEqual(len(read_rows(self.path)), 1)

    def test_second_run_is_refused_while_the_first_holds_the_lock(self) -> None:
        with self.open():
            with self.assertRaises(LedgerLocked) as caught:
                with self.open():
                    pass
        self.assertIn("papers_ledger.csv", str(caught.exception))
        with self.open():  # the lock is free once the first run ends
            pass

    def test_a_torn_row_is_reported_not_skipped(self) -> None:
        with self.open() as ledger:
            ledger.append(key="a-1", doi="d", stage=FETCH, state="fetched")
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write("2026,a-2,d\n")
        with self.assertRaises(LedgerError) as caught:
            read_rows(self.path)
        self.assertIn("3 fields", str(caught.exception))

    def test_detail_is_one_line_and_bounded(self) -> None:
        with self.open() as ledger:
            row = ledger.append(
                key="a-1", doi="d", stage=FETCH, state="failed", detail="line one\nline two\t" + "x" * 900
            )
        self.assertNotIn("\n", row.detail)
        self.assertEqual(len(row.detail), 500)
        self.assertEqual(len(read_rows(self.path)), 1)

    def test_ledger_never_stores_a_secret_from_the_environment_or_an_address(self) -> None:
        environ = {"ZOTERO_API_KEY": SECRET}
        with self.open(environ) as ledger:
            ledger.append(
                key="a-1",
                doi="d",
                stage=FETCH,
                state="failed",
                url=f"https://example.org/x?api_key=abc123&page=2",
                detail=f"server said {SECRET} is wrong",
            )
        stored = self.path.read_text(encoding="utf-8")
        self.assertNotIn(SECRET, stored)
        self.assertNotIn("abc123", stored)
        self.assertIn("[redacted:ZOTERO_API_KEY]", stored)
        self.assertIn("page=2", stored)

    def test_tool_hashes_are_the_tools_own_files_for_one_key_and_never_a_hand_file(self) -> None:
        with self.open() as ledger:
            ledger.append(key="a-1", doi="d", stage=FETCH, state="fetched", sha256="h1")
            ledger.append(key="a-1", doi="d", stage=FETCH, state="converted", sha256="h2")
            ledger.append(key="a-1", doi="d", stage=FETCH, state="converted", source="hand", sha256="h4")
            ledger.append(key="b-1", doi="d", stage=FETCH, state="fetched", sha256="h3")
        self.assertEqual(tool_hashes(read_rows(self.path), "a-1"), {"h1", "h2"})


class ScrubTests(unittest.TestCase):
    def test_short_values_and_unrelated_names_are_left_alone(self) -> None:
        environ = {"MONKEY": "1", "API_TOKEN": "short", "HOME": "/Users/someone/long-home-path"}
        text = "count 1 token short home /Users/someone/long-home-path"
        self.assertEqual(scrub(text, environ), text)

    def test_password_auth_and_credential_variables_are_covered_too(self) -> None:
        environ = {"DB_PASSWORD": "hunter2hunter2", "SSH_AUTH_SOCK": "/tmp/agent.socket.12345", "AWS_CREDENTIALS": "AKIA0123456789AB"}
        text = "hunter2hunter2 /tmp/agent.socket.12345 AKIA0123456789AB"
        self.assertEqual(
            scrub(text, environ),
            "[redacted:DB_PASSWORD] [redacted:SSH_AUTH_SOCK] [redacted:AWS_CREDENTIALS]",
        )

    def test_value_of_a_secret_named_variable_is_replaced_everywhere(self) -> None:
        environ = {"SERVICE_SECRET": SECRET}
        self.assertEqual(
            scrub(f"{SECRET} and again {SECRET}", environ),
            "[redacted:SERVICE_SECRET] and again [redacted:SERVICE_SECRET]",
        )

    def test_credential_query_parameters_are_redacted_and_others_kept(self) -> None:
        text = "GET https://x.org/a?Key=AAA&token=BBB&access_token=CCC&q=hello"
        self.assertEqual(
            scrub(text, {}),
            "GET https://x.org/a?Key=[redacted]&token=[redacted]&access_token=[redacted]&q=hello",
        )


if __name__ == "__main__":
    unittest.main()

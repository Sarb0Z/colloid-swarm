#!/usr/bin/env python3
"""Credential masking and the length cut for every text the phone link sends off the machine.

`outbound(text)` is the one call a sender needs: it replaces each credential
with `[REDACTED]`, then keeps the first 600 characters and says how many it
dropped, and it returns how many values it masked and characters it cut, so
the alert can say that it does not show the whole call. Masking comes first, so a credential that straddles the cut is gone
before the cut can leave half of it.

The patterns are the high-confidence table of
`.agents/skills/security-scan/SKILL.md`, which is prose only, kept here as
code. Three rows differ from that table, each toward masking more:

  - A private key masks from its BEGIN line through the key lines after it
    and its END line. With no END line, it masks the BEGIN line's marker and
    the key lines that follow it and no more. The table matches the BEGIN line
    alone, which would leave the key itself in the alert; masking to the end of
    the text would hide the command that a `yes` runs.
  - A database URL's user and password hold no shell syntax: in
    `postgres://u:$(…)@host` the `$(…)` is a command, not a password.
  - A value assigned to a name that holds secret, token, key, password, passwd,
    apikey or auth masks at 32 characters whatever its entropy. The table's
    entropy floor keeps a commit gate from firing on a UUID; here a masked UUID
    costs nothing and an unmasked 40-digit hex token is a leak. The value may
    follow a scheme word (`Authorization: Bearer <value>`).
  - The table's `.env` row names a staged path, not a text, and has no pattern
    here: the values of such a file fall under the assigned-value row.
"""

from __future__ import annotations

import re
from typing import NamedTuple

REDACTED = "[REDACTED]"
CUT = 600

_KEY_KIND = r"(?:RSA |DSA |EC |OPENSSH |PGP )?"
# A key's lines are broken by a newline, or by `\n` as a JSON string or a printf
# argument writes it. Between BEGIN and END only key lines count: base64, or an
# encrypted key's header field, so a command written between the two stays visible.
_LINE_BREAK = r"(?:\r?\n|\\n)"
_PEM_HEADER = r"(?:Proc-Type|DEK-Info|Version|Comment): [A-Za-z0-9 ,.-]*"
# What a shell reads as syntax: a URL password never holds it, so a command
# substitution or a pipe in its place stays visible.
_SHELL = r"\s$`()'\";|&<>"
# The name starts where its run of name characters starts, so a megabyte of them is
# scanned once and not once from every offset.
_ASSIGNED = re.compile(
    r"""(?ix)
    (?<![\w.-])(?P<name>[\w.-]*(?:secret|token|key|password|passwd|apikey|auth)[\w.-]*)
    (?P<gap>["']?\s*[:=]\s*["']?(?:(?:bearer|basic|token)\s+)?)
    (?P<value>[A-Za-z0-9+/=_-]{32,})
    """
)

# (class, pattern): each whole match becomes [REDACTED]. Order matters where one
# pattern is a prefix of another: the Anthropic key before the OpenAI one.
PATTERNS = (
    ("AWS access key id", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("AWS secret key", re.compile(r"aws_secret_access_key\s*=\s*[A-Za-z0-9/+=]{40}")),
    ("GCP service account", re.compile(r'"type":\s*"service_account"')),
    ("Private key block", re.compile(
        rf"-----BEGIN {_KEY_KIND}PRIVATE KEY-----"
        rf"(?:{_LINE_BREAK}(?:{_PEM_HEADER}|[A-Za-z0-9+/=]*)(?={_LINE_BREAK}|\Z))*"
        rf"(?:{_LINE_BREAK}-----END {_KEY_KIND}PRIVATE KEY-----)?")),
    ("GitHub token", re.compile(r"gh[pousr]_[A-Za-z0-9_]{36,}")),
    ("GitHub fine-grained PAT", re.compile(r"github_pat_[A-Za-z0-9_]{82}")),
    ("Slack token", re.compile(r"xox[abprs]-[A-Za-z0-9-]+")),
    ("Stripe live secret key", re.compile(r"sk_live_[A-Za-z0-9]{24,}")),
    ("Stripe live restricted key", re.compile(r"rk_live_[A-Za-z0-9]{24,}")),
    ("Anthropic key", re.compile(r"sk-ant-[A-Za-z0-9_-]{90,}")),
    ("OpenAI key", re.compile(r"sk-[A-Za-z0-9]{32,}")),
    ("JWT", re.compile(r"eyJ[A-Za-z0-9_=-]+\.eyJ[A-Za-z0-9_=-]+\.[A-Za-z0-9_=-]+")),
    ("DB URL with credentials", re.compile(
        rf"(?:postgres|postgresql|mysql|mongodb(?:\+srv)?)://[^:@/{_SHELL}]+:[^@{_SHELL}]+@")),
)


class Outbound(NamedTuple):
    text: str  # masked, then cut
    masked: int  # how many values were replaced by [REDACTED]
    cut: int  # how many characters the cut dropped


def masked(text: str) -> tuple[str, int]:
    """(`text` with each credential replaced by [REDACTED], how many were replaced).
    Masked text masks to itself, with a count of 0."""
    count = 0
    for _name, pattern in PATTERNS:
        text, found = pattern.subn(REDACTED, text)
        count += found
    # The assigned-value row keeps the name, so the reader still sees which variable was set.
    text, found = _ASSIGNED.subn(lambda match: match.group("name") + match.group("gap") + REDACTED, text)
    return text, count + found


def mask(text: str) -> str:
    """`text` with each credential replaced by [REDACTED]."""
    return masked(text)[0]


def cut(text: str) -> tuple[str, int]:
    """(the first CUT characters of `text` ending with how many were dropped, that number);
    shorter text as it is, with 0."""
    if len(text) <= CUT:
        return text, 0
    dropped = len(text) - CUT
    return f"{text[:CUT]}[… {dropped} more characters]", dropped


def outbound(text: str) -> Outbound:
    """What may leave the machine in place of `text`: masked, then cut, with both counts."""
    text, replaced = masked(text)
    text, dropped = cut(text)
    return Outbound(text, replaced, dropped)

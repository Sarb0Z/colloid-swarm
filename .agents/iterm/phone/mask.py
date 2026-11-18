#!/usr/bin/env python3
"""Credential masking and the length cut for every text the phone link sends off the machine.

`outbound(text)` is the one call a sender needs: it replaces each credential
with `[REDACTED]`, then keeps the first 600 characters and says how many it
dropped. Masking comes first, so a credential that straddles the cut is gone
before the cut can leave half of it.

The patterns are the high-confidence table of
`.agents/skills/security-scan/SKILL.md`, which is prose only, kept here as
code. Three rows differ from that table, each toward masking more:

  - A private key masks from its BEGIN line to its END line, or to the end of
    the text when the END line is cut off. The table matches the BEGIN line
    alone, which would leave the key itself in the alert.
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

REDACTED = "[REDACTED]"
CUT = 600

_KEY_KIND = r"(?:RSA |DSA |EC |OPENSSH |PGP )?"
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
        rf"-----BEGIN {_KEY_KIND}PRIVATE KEY-----[\s\S]*?(?:-----END {_KEY_KIND}PRIVATE KEY-----|\Z)")),
    ("GitHub token", re.compile(r"gh[pousr]_[A-Za-z0-9_]{36,}")),
    ("GitHub fine-grained PAT", re.compile(r"github_pat_[A-Za-z0-9_]{82}")),
    ("Slack token", re.compile(r"xox[abprs]-[A-Za-z0-9-]+")),
    ("Stripe live secret key", re.compile(r"sk_live_[A-Za-z0-9]{24,}")),
    ("Stripe live restricted key", re.compile(r"rk_live_[A-Za-z0-9]{24,}")),
    ("Anthropic key", re.compile(r"sk-ant-[A-Za-z0-9_-]{90,}")),
    ("OpenAI key", re.compile(r"sk-[A-Za-z0-9]{32,}")),
    ("JWT", re.compile(r"eyJ[A-Za-z0-9_=-]+\.eyJ[A-Za-z0-9_=-]+\.[A-Za-z0-9_=-]+")),
    ("DB URL with credentials", re.compile(r"(?:postgres|postgresql|mysql|mongodb(?:\+srv)?)://[^:\s]+:[^@\s]+@")),
)


def mask(text: str) -> str:
    """`text` with each credential replaced by [REDACTED]. Masked text masks to itself."""
    for _name, pattern in PATTERNS:
        text = pattern.sub(REDACTED, text)
    # The assigned-value row keeps the name, so the reader still sees which variable was set.
    return _ASSIGNED.sub(lambda found: found.group("name") + found.group("gap") + REDACTED, text)


def cut(text: str) -> str:
    """The first CUT characters of `text`, ending with how many were dropped; shorter text as it is."""
    if len(text) <= CUT:
        return text
    return f"{text[:CUT]}[… {len(text) - CUT} more characters]"


def outbound(text: str) -> str:
    """What may leave the machine in place of `text`: masked, then cut."""
    return cut(mask(text))

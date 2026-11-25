"""Keep secrets out of anything the tool prints or stores.

A plugin reads its secrets from the environment, so the tool cannot know them in
advance. It redacts by variable name, and it redacts the query parameters that
carry a credential inside an address.
"""

from __future__ import annotations

import re
from collections.abc import Mapping

SECRET_NAME = re.compile(r"KEY|TOKEN|SECRET", re.IGNORECASE)
# A value shorter than this is as likely to be a flag or a number as a secret,
# and replacing it would corrupt unrelated text.
MIN_SECRET_LENGTH = 8
QUERY_SECRET = re.compile(
    r"(?i)\b(key|api_key|apikey|token|access_token|secret|password)=([^&\s\"']+)"
)


def scrub(text: str, environ: Mapping[str, str]) -> str:
    secrets = sorted(
        (
            (name, value)
            for name, value in environ.items()
            if len(value) >= MIN_SECRET_LENGTH and SECRET_NAME.search(name)
        ),
        key=lambda pair: len(pair[1]),
        reverse=True,
    )
    for name, value in secrets:
        text = text.replace(value, f"[redacted:{name}]")
    return QUERY_SECRET.sub(lambda match: f"{match.group(1)}=[redacted]", text)

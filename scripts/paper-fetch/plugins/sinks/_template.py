"""Template for a sink plugin: copy this file, drop the leading underscore, fill it in.

A sink stores a fetched paper somewhere else, such as a reference manager.

Rules:
- `plan` says what `push` would do. It gets a read-only client: any method but
  GET or HEAD raises, so a dry run cannot write. Return one line per action.
- `push` does the work with a client that may write. Return a dict of the ids the
  other system assigned; the ledger stores them. Make `push` safe to repeat: look
  the paper up before creating it. A write that must not repeat on a network error
  needs `idempotent=True` on that request and a token the server accepts once.
- Read the folder, never write in it. The project's quote checker takes exactly
  one text file per paper folder.
- Read secrets from the environment. The tool redacts values of variables whose
  names contain KEY, TOKEN or SECRET.
- Declare `MAX_REQUESTS_PER_HOST` when a run needs more than the push default of
  1000, and `HOST_INTERVALS_MS` for a host that asks for a slower pace.
"""

from pathlib import Path

from paperfetch.model import Paper

NAME = "example-sink"

# MAX_REQUESTS_PER_HOST = 2000
# HOST_INTERVALS_MS = {"api.example.org": 500}


def plan(paper: Paper, folder: Path, http) -> list[str]:
    return [f"would store {paper.key}"]


def push(paper: Paper, folder: Path, http) -> dict[str, str]:
    raise NotImplementedError

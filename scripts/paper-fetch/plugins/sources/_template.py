"""Template for a source plugin: copy this file, drop the leading underscore, fill it in.

A source answers one question: where might this paper's file be? It returns
candidate addresses and downloads nothing. The runner downloads each candidate
in order, checks it, saves the first good one, and moves on.

Rules:
- Make every request through `http`. It paces requests per host, retries, counts
  them against the per-host cap and prints each address. Do not open your own
  connections.
- Return `[]` when this source has nothing. Raise only for a failure the operator
  must see: the runner reports it and runs the next source.
- Declare `HOST_INTERVALS_MS` for a host whose terms ask for a slower pace. The
  client uses the larger of that and the base delay.
- Read secrets from the environment, never from a file in this folder. The tool
  redacts values of variables whose names contain KEY, TOKEN or SECRET.
"""

from paperfetch.model import Candidate, Paper

# The name `--sources` takes: lower case letters, digits and hyphens.
NAME = "example"

# Minimum milliseconds between two requests to a host.
# HOST_INTERVALS_MS = {"api.example.org": 3000}


def locate(paper: Paper, http) -> list[Candidate]:
    """Return the addresses that might serve this paper.

    `paper.doi`, `paper.key` and `paper.row` (the whole manifest row) are the
    inputs. `http.get(url)` returns a response with `.status`, `.headers` (lower
    case names), `.body` (bytes) and `.url` (the final address).
    """
    # response = http.get(f"https://api.example.org/works/{paper.doi}")
    # return [Candidate(url=address, kind="pdf", source=NAME, license=None)]
    return []
